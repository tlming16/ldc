/**
 * Compiler implementation of the $(LINK2 http://www.dlang.org, D programming language)
 *
 * Do mangling for C++ linkage.
 * This is the POSIX side of the implementation.
 * It exports two functions to C++, `toCppMangleItanium` and `cppTypeInfoMangleItanium`.
 *
 * Copyright: Copyright (C) 1999-2019 by The D Language Foundation, All Rights Reserved
 * Authors: Walter Bright, http://www.digitalmars.com
 * License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:    $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/cppmangle.d, _cppmangle.d)
 * Documentation:  https://dlang.org/phobos/dmd_cppmangle.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/cppmangle.d
 *
 * References:
 *  Follows Itanium C++ ABI 1.86 section 5.1
 *  http://refspecs.linux-foundation.org/cxxabi-1.86.html#mangling
 *  which is where the grammar comments come from.
 *
 * Bugs:
 *  https://issues.dlang.org/query.cgi
 *  enter `C++, mangling` as the keywords.
 */

module dmd.cppmangle;

import core.stdc.string;
import core.stdc.stdio;

import dmd.arraytypes;
import dmd.declaration;
import dmd.dsymbol;
import dmd.dtemplate;
import dmd.errors;
import dmd.expression;
import dmd.func;
import dmd.globals;
import dmd.id;
import dmd.identifier;
import dmd.mtype;
import dmd.nspace;
import dmd.root.outbuffer;
import dmd.root.rootobject;
import dmd.target;
import dmd.tokens;
import dmd.typesem;
import dmd.visitor;


// helper to check if an identifier is a C++ operator
enum CppOperator { Cast, Assign, Eq, Index, Call, Unary, Binary, OpAssign, Unknown }
package CppOperator isCppOperator(Identifier id)
{
    __gshared const(Identifier)[] operators = null;
    if (!operators)
        operators = [Id._cast, Id.assign, Id.eq, Id.index, Id.call, Id.opUnary, Id.opBinary, Id.opOpAssign];
    foreach (i, op; operators)
    {
        if (op == id)
            return cast(CppOperator)i;
    }
    return CppOperator.Unknown;
}

///
extern(C++) const(char)* toCppMangleItanium(Dsymbol s)
{
    //printf("toCppMangleItanium(%s)\n", s.toChars());
    OutBuffer buf;
    scope CppMangleVisitor v = new CppMangleVisitor(&buf, s.loc);
    v.mangleOf(s);
    return buf.extractString();
}

///
extern(C++) const(char)* cppTypeInfoMangleItanium(Dsymbol s)
{
    //printf("cppTypeInfoMangle(%s)\n", s.toChars());
    OutBuffer buf;
    buf.writestring("_ZTI");    // "TI" means typeinfo structure
    scope CppMangleVisitor v = new CppMangleVisitor(&buf, s.loc);
    v.cpp_mangle_name(s, false);
    return buf.extractString();
}

/******************************
 * Determine if sym is the 'primary' destructor, that is,
 * the most-aggregate destructor (the one that is defined as __xdtor)
 * Params:
 *      sym = Dsymbol
 * Returns:
 *      true if sym is the primary destructor for an aggregate
 */
bool isPrimaryDtor(const Dsymbol sym)
{
    const dtor = sym.isDtorDeclaration();
    if (!dtor)
        return false;
    const ad = dtor.isMember();
    assert(ad);
    return dtor == ad.primaryDtor;
}

/// Context used when processing pre-semantic AST
private struct Context
{
    /// Template instance of the function being mangled
    TemplateInstance ti;
    /// Function declaration we're mangling
    FuncDeclaration fd;
    /// Current type / expression being processed (semantically analyzed)
    RootObject res;

    @disable ref Context opAssign(ref Context other);
    @disable ref Context opAssign(Context other);

    /**
     * Helper function to track `res`
     *
     * Params:
     *   next = Value to set `this.res` to.
     *          If `this.res` is `null`, the expression is not evalutated.
     *          This allow this code to be used even when no context is needed.
     *
     * Returns:
     *   The previous state of this `Context` object
     */
    private Context push(lazy RootObject next)
    {
        auto r = this.res;
        if (r !is null)
            this.res = next;
        return Context(this.ti, this.fd, r);
    }

    /**
     * Reset the context to a previous one, making any adjustment necessary
     */
    private void pop(ref Context prev)
    {
        this.res = prev.res;
    }
}

private final class CppMangleVisitor : Visitor
{
    /// Context used when processing pre-semantic AST
    private Context context;

    Objects components;         // array of components available for substitution
    OutBuffer* buf;             // append the mangling to buf[]
    Loc loc;                    // location for use in error messages

    /**
     * Constructor
     *
     * Params:
     *   buf = `OutBuffer` to write the mangling to
     *   loc = `Loc` of the symbol being mangled
     */
    this(OutBuffer* buf, Loc loc)
    {
        this.buf = buf;
        this.loc = loc;
    }

    /*****
     * Entry point. Append mangling to buf[]
     * Params:
     *  s = symbol to mangle
     */
    void mangleOf(Dsymbol s)
    {
        if (VarDeclaration vd = s.isVarDeclaration())
        {
            mangle_variable(vd, false);
        }
        else if (FuncDeclaration fd = s.isFuncDeclaration())
        {
            mangle_function(fd);
        }
        else
        {
            assert(0);
        }
    }

    /**
     * Mangle the return type of a function
     *
     * This is called on a templated function type.
     * Context is set to the `FuncDeclaration`.
     *
     * Params:
     *   preSemantic = the `FuncDeclaration`'s `originalType`
     */
    void mangleReturnType(TypeFunction preSemantic)
    {
        auto tf = cast(TypeFunction)this.context.res.asFuncDecl().type;
        Type rt = preSemantic.nextOf();
        if (tf.isref)
            rt = rt.referenceTo();
        auto prev = this.context.push(tf.nextOf());
        scope (exit) this.context.pop(prev);
        this.headOfType(rt);
    }

    /**
     * Write a seq-id from an index number, excluding the terminating '_'
     *
     * Params:
     *   idx = the index in a substitution list.
     *         Note that index 0 has no value, and `S0_` would be the
     *         substitution at index 1 in the list.
     *
     * See-Also:
     *  https://itanium-cxx-abi.github.io/cxx-abi/abi.html#mangle.seq-id
     */
    private void writeSequenceFromIndex(size_t idx)
    {
        if (idx)
        {
            void write_seq_id(size_t i)
            {
                if (i >= 36)
                {
                    write_seq_id(i / 36);
                    i %= 36;
                }
                i += (i < 10) ? '0' : 'A' - 10;
                buf.writeByte(cast(char)i);
            }

            write_seq_id(idx - 1);
        }
    }

    bool substitute(RootObject p)
    {
        //printf("substitute %s\n", p ? p.toChars() : null);
        auto i = find(p);
        if (i >= 0)
        {
            //printf("\tmatch\n");
            /* Sequence is S_, S0_, .., S9_, SA_, ..., SZ_, S10_, ...
             */
            buf.writeByte('S');
            writeSequenceFromIndex(i);
            buf.writeByte('_');
            return true;
        }
        return false;
    }

    /******
     * See if `p` exists in components[]
     *
     * Note that components can contain `null` entries,
     * as the index used in mangling is based on the index in the array.
     *
     * If called with an object whose dynamic type is `Nspace`,
     * calls the `find(Nspace)` overload.
     *
     * Returns:
     *  index if found, -1 if not
     */
    int find(RootObject p)
    {
        //printf("find %p %d %s\n", p, p.dyncast(), p ? p.toChars() : null);
        scope v = new ComponentVisitor(p);
        foreach (i, component; components)
        {
            if (component)
                component.visitObject(v);
            if (v.result)
                return cast(int)i;
        }
        return -1;
    }

    /*********************
     * Append p to components[]
     */
    void append(RootObject p)
    {
        //printf("append %p %d %s\n", p, p.dyncast(), p ? p.toChars() : "null");
        components.push(p);
    }

    /**
     * Write an identifier preceded by its length
     *
     * Params:
     *   ident = `Identifier` to write to `this.buf`
     */
    void writeIdentifier(const ref Identifier ident)
    {
        const name = ident.toString();
        this.buf.print(name.length);
        this.buf.writestring(name);
    }

    /************************
     * Determine if symbol is indeed the global ::std namespace.
     * Params:
     *  s = symbol to check
     * Returns:
     *  true if it is ::std
     */
    static bool isStd(Dsymbol s)
    {
        return (s &&
                s.ident == Id.std &&    // the right name
                s.isNspace() &&         // g++ disallows global "std" for other than a namespace
                !getQualifier(s));      // at global level
    }

    /************************
     * Determine if type is a C++ fundamental type.
     * Params:
     *  t = type to check
     * Returns:
     *  true if it is a fundamental type
     */
    static bool isFundamentalType(Type t)
    {
        // First check the target whether some specific ABI is being followed.
        bool isFundamental = void;
        if (target.cppFundamentalType(t, isFundamental))
            return isFundamental;

        if (auto te = t.isTypeEnum())
        {
            // Peel off enum type from special types.
            if (te.sym.isSpecial())
                t = te.memType();
        }

        // Fundamental arithmetic types:
        // 1. integral types: bool, char, int, ...
        // 2. floating point types: float, double, real
        // 3. void
        // 4. null pointer: std::nullptr_t (since C++11)
        if (t.ty == Tvoid || t.ty == Tbool)
            return true;
        else if (t.ty == Tnull && global.params.cplusplus >= CppStdRevision.cpp11)
            return true;
        else
            return t.isTypeBasic() && (t.isintegral() || t.isreal());
    }

    /******************************
     * Write the mangled representation of a template argument.
     * Params:
     *  ti  = the template instance
     *  arg = the template argument index
     */
    void template_arg(TemplateInstance ti, size_t arg)
    {
        TemplateDeclaration td = ti.tempdecl.isTemplateDeclaration();
        assert(td);
        TemplateParameter tp = (*td.parameters)[arg];
        RootObject o = (*ti.tiargs)[arg];

        Objects* pctx;
        auto prev = this.context.push({
                TemplateInstance parentti;
                if (this.context.res.dyncast() == DYNCAST.dsymbol)
                    parentti = this.context.res.asFuncDecl().parent.isTemplateInstance();
                else
                    parentti = this.context.res.asType().toDsymbol(null).parent.isTemplateInstance();
                return (*parentti.tiargs)[arg];
            }());
        scope (exit) this.context.pop(prev);

        if (tp.isTemplateTypeParameter())
        {
            Type t = isType(o);
            assert(t);
            t.accept(this);
        }
        else if (TemplateValueParameter tv = tp.isTemplateValueParameter())
        {
            // <expr-primary> ::= L <type> <value number> E  # integer literal
            if (tv.valType.isintegral())
            {
                Expression e = isExpression(o);
                assert(e);
                buf.writeByte('L');
                tv.valType.accept(this);
                auto val = e.toUInteger();
                if (!tv.valType.isunsigned() && cast(sinteger_t)val < 0)
                {
                    val = -val;
                    buf.writeByte('n');
                }
                buf.print(val);
                buf.writeByte('E');
            }
            else
            {
                ti.error("Internal Compiler Error: C++ `%s` template value parameter is not supported", tv.valType.toChars());
                fatal();
            }
        }
        else if (tp.isTemplateAliasParameter())
        {
            // Passing a function as alias parameter is the same as passing
            // `&function`
            Dsymbol d = isDsymbol(o);
            Expression e = isExpression(o);
            if (d && d.isFuncDeclaration())
            {
                // X .. E => template parameter is an expression
                // 'ad'   => unary operator ('&')
                // L .. E => is a <expr-primary>
                buf.writestring("XadL");
                mangle_function(d.isFuncDeclaration());
                buf.writestring("EE");
            }
            else if (e && e.op == TOK.variable && (cast(VarExp)e).var.isVarDeclaration())
            {
                VarDeclaration vd = (cast(VarExp)e).var.isVarDeclaration();
                buf.writeByte('L');
                mangle_variable(vd, true);
                buf.writeByte('E');
            }
            else if (d && d.isTemplateDeclaration() && d.isTemplateDeclaration().onemember)
            {
                if (!substitute(d))
                {
                    cpp_mangle_name(d, false);
                }
            }
            else
            {
                ti.error("Internal Compiler Error: C++ `%s` template alias parameter is not supported", o.toChars());
                fatal();
            }
        }
        else if (tp.isTemplateThisParameter())
        {
            ti.error("Internal Compiler Error: C++ `%s` template this parameter is not supported", o.toChars());
            fatal();
        }
        else
        {
            assert(0);
        }
    }

    /******************************
     * Write the mangled representation of the template arguments.
     * Params:
     *  ti = the template instance
     *  firstArg = index of the first template argument to mangle
     *             (used for operator overloading)
     * Returns:
     *  true if any arguments were written
     */
    bool template_args(TemplateInstance ti, int firstArg = 0)
    {
        /* <template-args> ::= I <template-arg>+ E
         */
        if (!ti || ti.tiargs.dim <= firstArg)   // could happen if std::basic_string is not a template
            return false;
        buf.writeByte('I');
        foreach (i; firstArg .. ti.tiargs.dim)
        {
            TemplateDeclaration td = ti.tempdecl.isTemplateDeclaration();
            assert(td);
            TemplateParameter tp = (*td.parameters)[i];

            /*
             * <template-arg> ::= <type>               # type or template
             *                ::= X <expression> E     # expression
             *                ::= <expr-primary>       # simple expressions
             *                ::= I <template-arg>* E  # argument pack
             */
            if (TemplateTupleParameter tt = tp.isTemplateTupleParameter())
            {
                buf.writeByte('I');     // argument pack

                // mangle the rest of the arguments as types
                foreach (j; i .. (*ti.tiargs).dim)
                {
                    Type t = isType((*ti.tiargs)[j]);
                    assert(t);
                    t.accept(this);
                }

                buf.writeByte('E');
                break;
            }

            template_arg(ti, i);
        }
        buf.writeByte('E');
        return true;
    }


    void source_name(Dsymbol s)
    {
        //printf("source_name(%s)\n", s.toChars());
        if (TemplateInstance ti = s.isTemplateInstance())
        {
            if (!substitute(ti.tempdecl))
            {
                append(ti.tempdecl);
                this.writeIdentifier(ti.tempdecl.toAlias().ident);
            }
            template_args(ti);
        }
        else
            this.writeIdentifier(s.ident);
    }

    /********
     * See if s is actually an instance of a template
     * Params:
     *  s = symbol
     * Returns:
     *  if s is instance of a template, return the instance, otherwise return s
     */
    Dsymbol getInstance(Dsymbol s)
    {
        Dsymbol p = s.toParent3();
        if (p)
        {
            if (TemplateInstance ti = p.isTemplateInstance())
                return ti;
        }
        return s;
    }

    /********
     * Get qualifier for `s`, meaning the symbol
     * that s is in the symbol table of.
     * The module does not count as a qualifier, because C++
     * does not have modules.
     * Params:
     *  s = symbol that may have a qualifier
     *      s is rewritten to be TemplateInstance if s is one
     * Returns:
     *  qualifier, null if none
     */
    static Dsymbol getQualifier(Dsymbol s)
    {
        Dsymbol p = s.toParent3();
        return (p && !p.isModule()) ? p : null;
    }

    // Detect type char
    static bool isChar(RootObject o)
    {
        Type t = isType(o);
        return (t && t.equals(Type.tchar));
    }

    // Detect type ::std::char_traits<char>
    static bool isChar_traits_char(RootObject o)
    {
        return isIdent_char(Id.char_traits, o);
    }

    // Detect type ::std::allocator<char>
    static bool isAllocator_char(RootObject o)
    {
        return isIdent_char(Id.allocator, o);
    }

    // Detect type ::std::ident<char>
    static bool isIdent_char(Identifier ident, RootObject o)
    {
        Type t = isType(o);
        if (!t || t.ty != Tstruct)
            return false;
        Dsymbol s = (cast(TypeStruct)t).toDsymbol(null);
        if (s.ident != ident)
            return false;
        Dsymbol p = s.toParent3();
        if (!p)
            return false;
        TemplateInstance ti = p.isTemplateInstance();
        if (!ti)
            return false;
        Dsymbol q = getQualifier(ti);
        return isStd(q) && ti.tiargs.dim == 1 && isChar((*ti.tiargs)[0]);
    }

    /***
     * Detect template args <char, ::std::char_traits<char>>
     * and write st if found.
     * Returns:
     *  true if found
     */
    bool char_std_char_traits_char(TemplateInstance ti, string st)
    {
        if (ti.tiargs.dim == 2 &&
            isChar((*ti.tiargs)[0]) &&
            isChar_traits_char((*ti.tiargs)[1]))
        {
            buf.writestring(st.ptr);
            return true;
        }
        return false;
    }


    void prefix_name(Dsymbol s)
    {
        //printf("prefix_name(%s)\n", s.toChars());
        if (substitute(s))
            return;

        auto si = getInstance(s);
        Dsymbol p = getQualifier(si);
        if (p)
        {
            if (isStd(p))
            {
                bool needsTa;
                auto ti = si.isTemplateInstance();
                if (this.writeStdSubstitution(ti, needsTa))
                {
                    if (needsTa)
                    {
                        template_args(ti);
                        append(ti);
                    }
                    return;
                }
                buf.writestring("St");
            }
            else
                prefix_name(p);
        }
        source_name(si);
        if (!isStd(si))
            /* Do this after the source_name() call to keep components[]
             * in the right order.
             * https://issues.dlang.org/show_bug.cgi?id=17947
             */
            append(si);
    }

    /**
     * Write common substitution for standard types, such as std::allocator
     *
     * This function assumes that the symbol `ti` is in the namespace `std`.
     *
     * Params:
     *   ti = Template instance to consider
     *   needsTa = If this function returns `true`, this value indicates
     *             if additional template argument mangling is needed
     *
     * Returns:
     *   `true` if a special std symbol was found
     */
    bool writeStdSubstitution(TemplateInstance ti, out bool needsTa)
    {
        if (!ti)
            return false;

        if (ti.name == Id.allocator)
        {
            buf.writestring("Sa");
            needsTa = true;
            return true;
        }
        if (ti.name == Id.basic_string)
        {
            // ::std::basic_string<char, ::std::char_traits<char>, ::std::allocator<char>>
            if (ti.tiargs.dim == 3 &&
                isChar((*ti.tiargs)[0]) &&
                isChar_traits_char((*ti.tiargs)[1]) &&
                isAllocator_char((*ti.tiargs)[2]))

            {
                buf.writestring("Ss");
                return true;
            }
            buf.writestring("Sb");      // ::std::basic_string
            needsTa = true;
            return true;
        }

        // ::std::basic_istream<char, ::std::char_traits<char>>
        if (ti.name == Id.basic_istream &&
            char_std_char_traits_char(ti, "Si"))
            return true;

        // ::std::basic_ostream<char, ::std::char_traits<char>>
        if (ti.name == Id.basic_ostream &&
            char_std_char_traits_char(ti, "So"))
            return true;

        // ::std::basic_iostream<char, ::std::char_traits<char>>
        if (ti.name == Id.basic_iostream &&
            char_std_char_traits_char(ti, "Sd"))
            return true;

        return false;
    }


    void cpp_mangle_name(Dsymbol s, bool qualified)
    {
        //printf("cpp_mangle_name(%s, %d)\n", s.toChars(), qualified);
        Dsymbol p = s.toParent3();
        Dsymbol se = s;
        bool write_prefix = true;
        if (p && p.isTemplateInstance())
        {
            se = p;
            if (find(p.isTemplateInstance().tempdecl) >= 0)
                write_prefix = false;
            p = p.toParent3();
        }
        if (p && !p.isModule())
        {
            /* The N..E is not required if:
             * 1. the parent is 'std'
             * 2. 'std' is the initial qualifier
             * 3. there is no CV-qualifier or a ref-qualifier for a member function
             * ABI 5.1.8
             */
            if (isStd(p) && !qualified)
            {
                TemplateInstance ti = se.isTemplateInstance();
                if (s.ident == Id.allocator)
                {
                    buf.writestring("Sa"); // "Sa" is short for ::std::allocator
                    template_args(ti);
                }
                else if (s.ident == Id.basic_string)
                {
                    // ::std::basic_string<char, ::std::char_traits<char>, ::std::allocator<char>>
                    if (ti.tiargs.dim == 3 &&
                        isChar((*ti.tiargs)[0]) &&
                        isChar_traits_char((*ti.tiargs)[1]) &&
                        isAllocator_char((*ti.tiargs)[2]))

                    {
                        buf.writestring("Ss");
                        return;
                    }
                    buf.writestring("Sb");      // ::std::basic_string
                    template_args(ti);
                }
                else
                {
                    // ::std::basic_istream<char, ::std::char_traits<char>>
                    if (s.ident == Id.basic_istream)
                    {
                        if (char_std_char_traits_char(ti, "Si"))
                            return;
                    }
                    else if (s.ident == Id.basic_ostream)
                    {
                        if (char_std_char_traits_char(ti, "So"))
                            return;
                    }
                    else if (s.ident == Id.basic_iostream)
                    {
                        if (char_std_char_traits_char(ti, "Sd"))
                            return;
                    }
                    buf.writestring("St");
                    source_name(se);
                }
            }
            else
            {
                buf.writeByte('N');
                if (write_prefix)
                {
                    if (isStd(p))
                        buf.writestring("St");
                    else
                        prefix_name(p);
                }
                source_name(se);
                buf.writeByte('E');
            }
        }
        else
            source_name(se);
        append(s);
    }

    /**
     * Write CV-qualifiers to the buffer
     *
     * CV-qualifiers are 'r': restrict (unused in D), 'V': volatile, 'K': const
     *
     * See_Also:
     *   https://itanium-cxx-abi.github.io/cxx-abi/abi.html#mangle.CV-qualifiers
     */
    void CV_qualifiers(const Type t)
    {
        if (t.isConst())
            buf.writeByte('K');
    }

    void mangle_variable(VarDeclaration d, bool is_temp_arg_ref)
    {
        // fake mangling for fields to fix https://issues.dlang.org/show_bug.cgi?id=16525
        if (!(d.storage_class & (STC.extern_ | STC.field | STC.gshared)))
        {
            d.error("Internal Compiler Error: C++ static non-`__gshared` non-`extern` variables not supported");
            fatal();
        }
        Dsymbol p = d.toParent3();
        if (p && !p.isModule()) //for example: char Namespace1::beta[6] should be mangled as "_ZN10Namespace14betaE"
        {
            buf.writestring("_ZN");
            prefix_name(p);
            source_name(d);
            buf.writeByte('E');
        }
        else //char beta[6] should mangle as "beta"
        {
            if (!is_temp_arg_ref)
            {
                buf.writestring(d.ident.toChars());
            }
            else
            {
                buf.writestring("_Z");
                source_name(d);
            }
        }
    }

    void mangle_function(FuncDeclaration d)
    {
        //printf("mangle_function(%s)\n", d.toChars());
        /*
         * <mangled-name> ::= _Z <encoding>
         * <encoding> ::= <function name> <bare-function-type>
         *            ::= <data name>
         *            ::= <special-name>
         */
        TypeFunction tf = cast(TypeFunction)d.type;
        buf.writestring("_Z");

        if (TemplateDeclaration ftd = getFuncTemplateDecl(d))
        {
            /* It's an instance of a function template
             */
            TemplateInstance ti = d.parent.isTemplateInstance();
            assert(ti);
            this.mangleTemplatedFunction(d, tf, ftd, ti);
        }
        else
        {
            Dsymbol p = d.toParent3();
            if (p && !p.isModule() && tf.linkage == LINK.cpp)
            {
                this.mangleNestedFuncPrefix(tf, p);

                if (d.isCtorDeclaration())
                    buf.writestring("C1");
                else if (d.isPrimaryDtor())
                    buf.writestring("D1");
                else if (d.ident && d.ident == Id.assign)
                    buf.writestring("aS");
                else if (d.ident && d.ident == Id.eq)
                    buf.writestring("eq");
                else if (d.ident && d.ident == Id.index)
                    buf.writestring("ix");
                else if (d.ident && d.ident == Id.call)
                    buf.writestring("cl");
                else
                    source_name(d);
                buf.writeByte('E');
            }
            else
            {
                source_name(d);
            }
            // Template args accept extern "C" symbols with special mangling
            if (tf.linkage == LINK.cpp)
                mangleFunctionParameters(tf.parameterList.parameters, tf.parameterList.varargs);
        }
    }

    /**
     * Mangles a function template to C++
     *
     * Params:
     *   d = Function declaration
     *   tf = Function type (casted d.type)
     *   ftd = Template declaration (ti.templdecl)
     *   ti = Template instance (d.parent)
     */
    void mangleTemplatedFunction(FuncDeclaration d, TypeFunction tf,
                                 TemplateDeclaration ftd, TemplateInstance ti)
    {
        Dsymbol p = ti.toParent3();
        // Check if this function is *not* nested
        if (!p || p.isModule() || tf.linkage != LINK.cpp)
        {
            this.context.ti = ti;
            this.context.fd = d;
            this.context.res = d;
            TypeFunction preSemantic = cast(TypeFunction)d.originalType;
            source_name(ti);
            this.mangleReturnType(preSemantic);
            this.mangleFunctionParameters(preSemantic.parameterList.parameters, tf.parameterList.varargs);
            return;
        }

        // It's a nested function (e.g. a member of an aggregate)
        this.mangleNestedFuncPrefix(tf, p);

        if (d.isCtorDeclaration())
        {
            buf.writestring("C1");
        }
        else if (d.isPrimaryDtor())
        {
            buf.writestring("D1");
        }
        else
        {
            int firstTemplateArg = 0;
            bool appendReturnType = true;
            bool isConvertFunc = false;
            string symName;

            // test for special symbols
            CppOperator whichOp = isCppOperator(ti.name);
            final switch (whichOp)
            {
            case CppOperator.Unknown:
                break;
            case CppOperator.Cast:
                symName = "cv";
                firstTemplateArg = 1;
                isConvertFunc = true;
                appendReturnType = false;
                break;
            case CppOperator.Assign:
                symName = "aS";
                break;
            case CppOperator.Eq:
                symName = "eq";
                break;
            case CppOperator.Index:
                symName = "ix";
                break;
            case CppOperator.Call:
                symName = "cl";
                break;
            case CppOperator.Unary:
            case CppOperator.Binary:
            case CppOperator.OpAssign:
                TemplateDeclaration td = ti.tempdecl.isTemplateDeclaration();
                assert(td);
                assert(ti.tiargs.dim >= 1);
                TemplateParameter tp = (*td.parameters)[0];
                TemplateValueParameter tv = tp.isTemplateValueParameter();
                if (!tv || !tv.valType.isString())
                    break; // expecting a string argument to operators!
                Expression exp = (*ti.tiargs)[0].isExpression();
                StringExp str = exp.toStringExp();
                switch (whichOp)
                {
                case CppOperator.Unary:
                    switch (str.peekSlice())
                    {
                    case "*":   symName = "de"; goto continue_template;
                    case "++":  symName = "pp"; goto continue_template;
                    case "--":  symName = "mm"; goto continue_template;
                    case "-":   symName = "ng"; goto continue_template;
                    case "+":   symName = "ps"; goto continue_template;
                    case "~":   symName = "co"; goto continue_template;
                    default:    break;
                    }
                    break;
                case CppOperator.Binary:
                    switch (str.peekSlice())
                    {
                    case ">>":  symName = "rs"; goto continue_template;
                    case "<<":  symName = "ls"; goto continue_template;
                    case "*":   symName = "ml"; goto continue_template;
                    case "-":   symName = "mi"; goto continue_template;
                    case "+":   symName = "pl"; goto continue_template;
                    case "&":   symName = "an"; goto continue_template;
                    case "/":   symName = "dv"; goto continue_template;
                    case "%":   symName = "rm"; goto continue_template;
                    case "^":   symName = "eo"; goto continue_template;
                    case "|":   symName = "or"; goto continue_template;
                    default:    break;
                    }
                    break;
                case CppOperator.OpAssign:
                    switch (str.peekSlice())
                    {
                    case "*":   symName = "mL"; goto continue_template;
                    case "+":   symName = "pL"; goto continue_template;
                    case "-":   symName = "mI"; goto continue_template;
                    case "/":   symName = "dV"; goto continue_template;
                    case "%":   symName = "rM"; goto continue_template;
                    case ">>":  symName = "rS"; goto continue_template;
                    case "<<":  symName = "lS"; goto continue_template;
                    case "&":   symName = "aN"; goto continue_template;
                    case "|":   symName = "oR"; goto continue_template;
                    case "^":   symName = "eO"; goto continue_template;
                    default:    break;
                    }
                    break;
                default:
                    assert(0);
                continue_template:
                    firstTemplateArg = 1;
                    break;
                }
                break;
            }
            if (symName.length == 0)
                source_name(ti);
            else
            {
                buf.writestring(symName);
                if (isConvertFunc)
                    template_arg(ti, 0);
                appendReturnType = template_args(ti, firstTemplateArg) && appendReturnType;
            }
            buf.writeByte('E');
            if (appendReturnType)
                headOfType(tf.nextOf());  // mangle return type
        }
        mangleFunctionParameters(tf.parameterList.parameters, tf.parameterList.varargs);
    }

    /**
     * Mangle the parameters of a function
     *
     * For templated functions, `context.res` is set to the `FuncDeclaration`
     *
     * Params:
     *   parameters = Array of `Parameter` to mangle
     *   varargs = if != 0, this function has varargs parameters
     */
    void mangleFunctionParameters(Parameters* parameters, VarArg varargs)
    {
        int numparams = 0;

        int paramsCppMangleDg(size_t n, Parameter fparam)
        {
            Type t = target.cppParameterType(fparam);
            if (t.ty == Tsarray)
            {
                // Static arrays in D are passed by value; no counterpart in C++
                .error(loc, "Internal Compiler Error: unable to pass static array `%s` to extern(C++) function, use pointer instead",
                    t.toChars());
                fatal();
            }
            auto prev = this.context.push({
                    auto tf = cast(TypeFunction)this.context.res.asFuncDecl().type;
                    return (*tf.parameterList.parameters)[n].type;
                }());
            scope (exit) this.context.pop(prev);
            headOfType(t);
            ++numparams;
            return 0;
        }

        if (parameters)
            Parameter._foreach(parameters, &paramsCppMangleDg);
        if (varargs == VarArg.variadic)
            buf.writeByte('z');
        else if (!numparams)
            buf.writeByte('v'); // encode (void) parameters
    }

    /****** The rest is type mangling ************/

    void error(Type t)
    {
        const(char)* p;
        if (t.isImmutable())
            p = "`immutable` ";
        else if (t.isShared())
            p = "`shared` ";
        else
            p = "";
        .error(loc, "Internal Compiler Error: %stype `%s` can not be mapped to C++\n", p, t.toChars());
        fatal(); //Fatal, because this error should be handled in frontend
    }

    /****************************
     * Mangle a type,
     * treating it as a Head followed by a Tail.
     * Params:
     *  t = Head of a type
     */
    void headOfType(Type t)
    {
        if (t.ty == Tclass)
        {
            mangleTypeClass(cast(TypeClass)t, true);
        }
        else
        {
            // For value types, strip const/immutable/shared from the head of the type
            auto prev = this.context.push(this.context.res.asType().mutableOf().unSharedOf());
            scope (exit) this.context.pop(prev);
            t.mutableOf().unSharedOf().accept(this);
        }
    }

    /******
     * Write out 1 or 2 character basic type mangling.
     * Handle const and substitutions.
     * Params:
     *  t = type to mangle
     *  p = if not 0, then character prefix
     *  c = mangling character
     */
    void writeBasicType(Type t, char p, char c)
    {
        // Only do substitutions for non-fundamental types.
        if (!isFundamentalType(t) || t.isConst())
        {
            if (substitute(t))
                return;
            else
                append(t);
        }
        CV_qualifiers(t);
        if (p)
            buf.writeByte(p);
        buf.writeByte(c);
    }


    /****************
     * Write structs and enums.
     * Params:
     *  t = TypeStruct or TypeEnum
     */
    void doSymbol(Type t)
    {
        if (substitute(t))
            return;
        CV_qualifiers(t);

        // Handle any target-specific struct types.
        if (auto tm = target.cppTypeMangle(t))
        {
            buf.writestring(tm);
        }
        else
        {
            Dsymbol s = t.toDsymbol(null);
            Dsymbol p = s.toParent3();
            if (p && p.isTemplateInstance())
            {
                 /* https://issues.dlang.org/show_bug.cgi?id=17947
                  * Substitute the template instance symbol, not the struct/enum symbol
                  */
                if (substitute(p))
                    return;
            }
            if (!substitute(s))
            {
                cpp_mangle_name(s, false);
            }
        }
        if (t.isConst())
            append(t);
    }



    /************************
     * Mangle a class type.
     * If it's the head, treat the initial pointer as a value type.
     * Params:
     *  t = class type
     *  head = true for head of a type
     */
    void mangleTypeClass(TypeClass t, bool head)
    {
        if (t.isImmutable() || t.isShared())
            return error(t);

        /* Mangle as a <pointer to><struct>
         */
        if (substitute(t))
            return;
        if (!head)
            CV_qualifiers(t);
        buf.writeByte('P');

        CV_qualifiers(t);

        {
            Dsymbol s = t.toDsymbol(null);
            Dsymbol p = s.toParent3();
            if (p && p.isTemplateInstance())
            {
                 /* https://issues.dlang.org/show_bug.cgi?id=17947
                  * Substitute the template instance symbol, not the class symbol
                  */
                if (substitute(p))
                    return;
            }
        }

        if (!substitute(t.sym))
        {
            cpp_mangle_name(t.sym, false);
        }
        if (t.isConst())
            append(null);  // C++ would have an extra type here
        append(t);
    }

    /**
     * Mangle the prefix of a nested (e.g. member) function
     *
     * Params:
     *   tf = Type of the nested function
     *   parent = Parent in which the function is nested
     */
    void mangleNestedFuncPrefix(TypeFunction tf, Dsymbol parent)
    {
        /* <nested-name> ::= N [<CV-qualifiers>] <prefix> <unqualified-name> E
         *               ::= N [<CV-qualifiers>] <template-prefix> <template-args> E
         */
        buf.writeByte('N');
        CV_qualifiers(tf);

        /* <prefix> ::= <prefix> <unqualified-name>
         *          ::= <template-prefix> <template-args>
         *          ::= <template-param>
         *          ::= # empty
         *          ::= <substitution>
         *          ::= <prefix> <data-member-prefix>
         */
        prefix_name(parent);
    }

extern(C++):

    alias visit = Visitor.visit;

    override void visit(TypeNull t)
    {
        if (t.isImmutable() || t.isShared())
            return error(t);

        writeBasicType(t, 'D', 'n');
    }

    override void visit(TypeBasic t)
    {
        if (t.isImmutable() || t.isShared())
            return error(t);

        // Handle any target-specific basic types.
        if (auto tm = target.cppTypeMangle(t))
        {
            // Only do substitutions for non-fundamental types.
            if (!isFundamentalType(t) || t.isConst())
            {
                if (substitute(t))
                    return;
                else
                    append(t);
            }
            CV_qualifiers(t);
            buf.writestring(tm);
            return;
        }

        /* <builtin-type>:
         * v        void
         * w        wchar_t
         * b        bool
         * c        char
         * a        signed char
         * h        unsigned char
         * s        short
         * t        unsigned short
         * i        int
         * j        unsigned int
         * l        long
         * m        unsigned long
         * x        long long, __int64
         * y        unsigned long long, __int64
         * n        __int128
         * o        unsigned __int128
         * f        float
         * d        double
         * e        long double, __float80
         * g        __float128
         * z        ellipsis
         * Dd       64 bit IEEE 754r decimal floating point
         * De       128 bit IEEE 754r decimal floating point
         * Df       32 bit IEEE 754r decimal floating point
         * Dh       16 bit IEEE 754r half-precision floating point
         * Di       char32_t
         * Ds       char16_t
         * u <source-name>  # vendor extended type
         */
        char c;
        char p = 0;
        switch (t.ty)
        {
            case Tvoid:                 c = 'v';        break;
            case Tint8:                 c = 'a';        break;
            case Tuns8:                 c = 'h';        break;
            case Tint16:                c = 's';        break;
            case Tuns16:                c = 't';        break;
            case Tint32:                c = 'i';        break;
            case Tuns32:                c = 'j';        break;
            case Tfloat32:              c = 'f';        break;
            case Tint64:
                c = target.c_longsize == 8 ? 'l' : 'x';
                break;
            case Tuns64:
                c = target.c_longsize == 8 ? 'm' : 'y';
                break;
            case Tint128:                c = 'n';       break;
            case Tuns128:                c = 'o';       break;
            case Tfloat64:               c = 'd';       break;
version (IN_LLVM)
{
            // there are special cases for D `real`, handled via Target.cppTypeMangle() in the default case
            case Tfloat80:               goto default;
}
else
{
            case Tfloat80:               c = 'e';       break;
}
            case Tbool:                  c = 'b';       break;
            case Tchar:                  c = 'c';       break;
            case Twchar:                 c = 't';       break;  // unsigned short (perhaps use 'Ds' ?
            case Tdchar:                 c = 'w';       break;  // wchar_t (UTF-32) (perhaps use 'Di' ?
            case Timaginary32:  p = 'G'; c = 'f';       break;  // 'G' means imaginary
            case Timaginary64:  p = 'G'; c = 'd';       break;
            case Timaginary80:  p = 'G'; c = 'e';       break;
            case Tcomplex32:    p = 'C'; c = 'f';       break;  // 'C' means complex
            case Tcomplex64:    p = 'C'; c = 'd';       break;
            case Tcomplex80:    p = 'C'; c = 'e';       break;

            default:
                return error(t);
        }
        writeBasicType(t, p, c);
    }

    override void visit(TypeVector t)
    {
        if (t.isImmutable() || t.isShared())
            return error(t);

        if (substitute(t))
            return;
        append(t);
        CV_qualifiers(t);

        // Handle any target-specific vector types.
        if (auto tm = target.cppTypeMangle(t))
        {
            buf.writestring(tm);
        }
        else
        {
            assert(t.basetype && t.basetype.ty == Tsarray);
            assert((cast(TypeSArray)t.basetype).dim);
            version (none)
            {
                buf.writestring("Dv");
                buf.print((cast(TypeSArray *)t.basetype).dim.toInteger()); // -- Gnu ABI v.4
                buf.writeByte('_');
            }
            else
                buf.writestring("U8__vector"); //-- Gnu ABI v.3
            t.basetype.nextOf().accept(this);
        }
    }

    override void visit(TypeSArray t)
    {
        if (t.isImmutable() || t.isShared())
            return error(t);

        if (!substitute(t))
            append(t);
        CV_qualifiers(t);
        buf.writeByte('A');
        buf.print(t.dim ? t.dim.toInteger() : 0);
        buf.writeByte('_');
        t.next.accept(this);
    }

    override void visit(TypePointer t)
    {
        if (t.isImmutable() || t.isShared())
            return error(t);

        // Check for const - Since we cannot represent C++'s `char* const`,
        // and `const char* const` (a.k.a `const(char*)` in D) is mangled
        // the same as `const char*` (`const(char)*` in D), we need to add
        // an extra `K` if `nextOf()` is `const`, before substitution
        CV_qualifiers(t);
        if (substitute(t))
            return;
        buf.writeByte('P');
        auto prev = this.context.push(this.context.res.asType().nextOf());
        scope (exit) this.context.pop(prev);
        t.next.accept(this);
        append(t);
    }

    override void visit(TypeReference t)
    {
        if (substitute(t))
            return;
        buf.writeByte('R');
        auto prev = this.context.push(this.context.res.asType().nextOf());
        scope (exit) this.context.pop(prev);
        t.next.accept(this);
        append(t);
    }

    override void visit(TypeFunction t)
    {
        /*
         *  <function-type> ::= F [Y] <bare-function-type> E
         *  <bare-function-type> ::= <signature type>+
         *  # types are possible return type, then parameter types
         */
        /* ABI says:
            "The type of a non-static member function is considered to be different,
            for the purposes of substitution, from the type of a namespace-scope or
            static member function whose type appears similar. The types of two
            non-static member functions are considered to be different, for the
            purposes of substitution, if the functions are members of different
            classes. In other words, for the purposes of substitution, the class of
            which the function is a member is considered part of the type of
            function."

            BUG: Right now, types of functions are never merged, so our simplistic
            component matcher always finds them to be different.
            We should use Type.equals on these, and use different
            TypeFunctions for non-static member functions, and non-static
            member functions of different classes.
         */
        if (substitute(t))
            return;
        buf.writeByte('F');
        if (t.linkage == LINK.c)
            buf.writeByte('Y');
        Type tn = t.next;
        if (t.isref)
            tn = tn.referenceTo();
        tn.accept(this);
        mangleFunctionParameters(t.parameterList.parameters, t.parameterList.varargs);
        buf.writeByte('E');
        append(t);
    }

    override void visit(TypeStruct t)
    {
        if (t.isImmutable() || t.isShared())
            return error(t);
        //printf("TypeStruct %s\n", t.toChars());
        doSymbol(t);
    }

    override void visit(TypeEnum t)
    {
        if (t.isImmutable() || t.isShared())
            return error(t);

        /* __c_(u)long(long) get special mangling
         */
        const id = t.sym.ident;
        //printf("enum id = '%s'\n", id.toChars());
        if (id == Id.__c_long)
            return writeBasicType(t, 0, 'l');
        else if (id == Id.__c_ulong)
            return writeBasicType(t, 0, 'm');
        else if (id == Id.__c_wchar_t)
            return writeBasicType(t, 0, 'w');
        else if (id == Id.__c_longlong)
            return writeBasicType(t, 0, 'x');
        else if (id == Id.__c_ulonglong)
            return writeBasicType(t, 0, 'y');

        doSymbol(t);
    }

    override void visit(TypeClass t)
    {
        mangleTypeClass(t, false);
    }

    /**
     * Performs template parameter substitution
     *
     * Mangling is performed on a copy of the post-parsing AST before
     * any semantic pass is run.
     * There is no easy way to link a type to the template parameters
     * once semantic has run, because:
     * - the `TemplateInstance` installs aliases in its scope to its params
     * - `AliasDeclaration`s are resolved in many places
     * - semantic passes are destructive, so the `TypeIdentifier` gets lost
     *
     * As a result, the best approach with the current architecture is to:
     * - Run the visitor on the `originalType` of the function,
     *   looking up any `TypeIdentifier` at the template scope when found.
     * - Fallback to the post-semantic `TypeFunction` when the identifier is
     *   not a template parameter.
     */
    override void visit(TypeIdentifier t)
    {
        auto decl = cast(TemplateDeclaration)this.context.ti.tempdecl;
        assert(decl.parameters !is null);
        // If not found, default to the post-semantic type
        if (!this.writeTemplateSubstitution(t.ident, decl.parameters, this.context.res.isType()))
            this.context.res.visitObject(this);
    }

    /// Ditto
    override void visit(TypeInstance t)
    {
        assert(t.tempinst !is null);
        t.tempinst.accept(this);
    }

    /// Ditto
    override void visit(TemplateInstance t)
    {
        assert(t.name !is null);
        assert(t.tiargs !is null);

        if (this.substitute(t))
            return;
        auto topdecl = cast(TemplateDeclaration)this.context.ti.tempdecl;
        // Template names are substituted, but args still need to be written
        bool needclosing;
        if (!this.writeTemplateSubstitution(t.name, topdecl.parameters, t.getType()))
        {
            needclosing = this.writeQualified(t);
            this.append(t);
        }
        buf.writeByte('I');
        // When visiting the arguments, the context will be set to the
        // resolved type
        auto analyzed_ti = this.context.res.asType().toDsymbol(null).isInstantiated();
        auto prev = this.context;
        scope (exit) this.context.pop(prev);
        foreach (idx, RootObject o; *t.tiargs)
        {
            this.context.res = (*analyzed_ti.tiargs)[idx];
            o.visitObject(this);
        }
        if (analyzed_ti.tiargs.dim > t.tiargs.dim)
        {
            // If the resolved AST has more args than the parse one,
            // we have default arguments
            auto oparams = (cast(TemplateDeclaration)analyzed_ti.tempdecl).origParameters;
            foreach (idx, arg; (*oparams)[t.tiargs.dim .. $])
            {
                this.context.res = (*analyzed_ti.tiargs)[idx + t.tiargs.dim];

                if (auto ttp = arg.isTemplateTypeParameter())
                    ttp.defaultType.accept(this);
                else if (auto tvp = arg.isTemplateValueParameter())
                    tvp.defaultValue.accept(this);
                else if (auto tvp = arg.isTemplateThisParameter())
                    tvp.defaultType.accept(this);
                else if (auto tvp = arg.isTemplateAliasParameter())
                    tvp.defaultAlias.visitObject(this);
                else
                    assert(0, arg.toString());
            }
        }
        buf.writeByte('E');
        if (needclosing)
            buf.writeByte('E');
    }

    /// Ditto
    override void visit(IntegerExp t)
    {
        this.buf.writeByte('L');
        t.type.accept(this);
        this.buf.print(t.getInteger());
        this.buf.writeByte('E');
    }

    override void visit(Nspace t)
    {
        if (auto p = getQualifier(t))
            p.accept(this);

        if (isStd(t))
            buf.writestring("St");
        else
        {
            this.writeIdentifier(t.ident);
            this.append(t);
        }
    }

    override void visit(Type t)
    {
        error(t);
    }

    void visit(Tuple t)
    {
        assert(0);
    }

    /**
     * Helper function to go through the `TemplateParameter`s and perform
     * a substitution, if possible.
     *
     * Params:
     *   ident = Identifier for which substitution is attempted
     *           (e.g. `void func(T)(T param)` => `T` from `T param`)
     *   params = `TemplateParameters` of the enclosing symbol
     *           (in the previous example, `func`'s template parameters)
     *   type = Resolved type of `T`, so that `void func(T)(const T)`
     *          gets mangled correctly
     *
     * Returns:
     *   `true` if something was written to the buffer
     */
    private bool writeTemplateSubstitution(const ref Identifier ident,
        TemplateParameters* params, Type type)
    {
        foreach (idx, param; *params)
        {
            if (param.ident == ident)
            {
                if (type)
                    CV_qualifiers(type);
                if (this.substitute(param))
                    return true;
                this.append(param);

                // expressions are mangled in <X..E>
                if (param.isTemplateValueParameter())
                    buf.writeByte('X');
                buf.writeByte('T');
                writeSequenceFromIndex(idx);
                buf.writeByte('_');
                if (param.isTemplateValueParameter())
                    buf.writeByte('E');
                return true;
            }
        }
        return false;
    }

    /**
     * Given a template instance `t`, write its qualified name
     * without the template parameter list
     *
     * Params:
     *   t = Post-parsing `TemplateInstance` pointing to the symbol
     *       to mangle (one level deep)
     *
     * Returns:
     *   `true` if the name was qualified and requires an ending `E`
     */
    private bool writeQualified(TemplateInstance t)
    {
        auto type = isType(this.context.res);
        if (!type)
        {
            this.writeIdentifier(t.name);
            return false;
        }
        auto sym = type.toDsymbol(null);
        if (!sym)
        {
            this.writeIdentifier(t.name);
            return false;
        }
        // Get the template instance
        sym = getQualifier(sym);
        auto sym2 = getQualifier(sym);
        if (sym2)
        {
            if (isStd(sym2))
            {
                bool unused;
                assert(sym.isTemplateInstance());
                if (this.writeStdSubstitution(sym.isTemplateInstance(), unused))
                    return false;
                // std names don't require `N..E`
                buf.writestring("St");
                this.writeIdentifier(t.name);
                return false;
            }
            buf.writestring("N");
            if (!this.substitute(sym2))
                sym2.accept(this);
        }
        this.writeIdentifier(t.name);
        return sym2 !is null;
    }
}

/// Helper code to visit `RootObject`, as it doesn't define `accept`,
/// only its direct subtypes do.
private void visitObject(V : Visitor)(RootObject o, V this_)
{
    assert(o !is null);
    if (Type ta = isType(o))
        ta.accept(this_);
    else if (Expression ea = isExpression(o))
        ea.accept(this_);
    else if (Dsymbol sa = isDsymbol(o))
        sa.accept(this_);
    else if (TemplateParameter t = isTemplateParameter(o))
        t.accept(this_);
    else if (Tuple t = isTuple(o))
        // `Tuple` inherits `RootObject` and does not define accept
        // For this reason, this uses static dispatch on the visitor
        this_.visit(t);
    else
        assert(0, o.toString());
}

/// Helper function to safely get a type out of a `RootObject`
private Type asType(RootObject o)
{
    Type ta = isType(o);
    assert(ta !is null, o.toString());
    return ta;
}

/// Helper function to safely get a `FuncDeclaration` out of a `RootObject`
private FuncDeclaration asFuncDecl(RootObject o)
{
    Dsymbol d = isDsymbol(o);
    assert(d !is null);
    auto fd = d.isFuncDeclaration();
    assert(fd !is null);
    return fd;
}

/// Helper class to compare entries in components
private extern(C++) final class ComponentVisitor : Visitor
{
    /// Only one of the following is not `null`, it's always
    /// the most specialized type, set from the ctor
    private Nspace namespace;

    /// Ditto
    private TypePointer tpointer;

    /// Ditto
    private TypeReference tref;

    /// Ditto
    private TypeIdentifier tident;

    /// Least specialized type
    private RootObject object;

    /// Set to the result of the comparison
    private bool result;

    public this(RootObject base)
    {
        switch (base.dyncast())
        {
        case DYNCAST.dsymbol:
            if (auto ns = (cast(Dsymbol)base).isNspace())
                this.namespace = ns;
            else
                goto default;
            break;

        case DYNCAST.type:
            auto t = cast(Type)base;
            if (t.ty == Tpointer)
                this.tpointer = cast(TypePointer)t;
            else if (t.ty == Treference)
                this.tref = cast(TypeReference)t;
            else if (t.ty == Tident)
                this.tident = cast(TypeIdentifier)t;
            else
                goto default;
            break;

        default:
            this.object = base;
        }
    }

    /// Introduce base class overloads
    alias visit = Visitor.visit;

    /// Least specialized overload of each direct child of `RootObject`
    public override void visit(Dsymbol o)
    {
        this.result = this.object && this.object == o;
    }

    /// Ditto
    public override void visit(Expression o)
    {
        this.result = this.object && this.object == o;
    }

    /// Ditto
    public void visit(Tuple o)
    {
        this.result = this.object && this.object == o;
    }

    /// Ditto
    public override void visit(Type o)
    {
        this.result = this.object && this.object == o;
    }

    /// Ditto
    public override void visit(TemplateParameter o)
    {
        this.result = this.object && this.object == o;
    }

    /**
     * This overload handles composed types including template parameters
     *
     * Components for substitutions include "next" type.
     * For example, if `ref T` is present, `ref T` and `T` will be present
     * in the substitution array.
     * But since we don't have the final/merged type, we cannot rely on
     * object comparison, and need to recurse instead.
     */
    public override void visit(TypeReference o)
    {
        if (!this.tref)
            return;
        if (this.tref == o)
            this.result = true;
        else
        {
            // It might be a reference to a template parameter that we already
            // saw, so we need to recurse
            scope v = new ComponentVisitor(this.tref.next);
            o.next.visitObject(v);
            this.result = v.result;
        }
    }

    /// Ditto
    public override void visit(TypePointer o)
    {
        if (!this.tpointer)
            return;
        if (this.tpointer == o)
            this.result = true;
        else
        {
            // It might be a pointer to a template parameter that we already
            // saw, so we need to recurse
            scope v = new ComponentVisitor(this.tpointer.next);
            o.next.visitObject(v);
            this.result = v.result;
        }
    }

    /// Ditto
    public override void visit(TypeIdentifier o)
    {
        /// Since we know they are at the same level, scope resolution will
        /// give us the same symbol, thus we can just compare ident.
        this.result = (this.tident && (this.tident.ident == o.ident));
    }

    /**
     * Overload which accepts a Namespace
     *
     * It is very common for large C++ projects to have multiple files sharing
     * the same `namespace`. If any D project adopts the same approach
     * (e.g. separating data structures from functions), it will lead to two
     * `Nspace` objects being instantiated, with different addresses.
     * At the same time, we cannot compare just any Dsymbol via identifier,
     * because it messes with templates.
     *
     * See_Also:
     *  https://issues.dlang.org/show_bug.cgi?id=18922
     *
     * Params:
     *   ns = C++ namespace to do substitution for
     */
    public override void visit(Nspace ns)
    {
        this.result = this.namespace && this.namespace.equals(ns);
    }
}
