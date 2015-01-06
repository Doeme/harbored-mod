/**
 * D Documentation Generator
 * Copyright: © 2014 Economic Modeling Specialists, Intl.
 * Authors: Brian Schott
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */
module visitor;

import config;
import ddoc.comments;
import formatter;
import std.algorithm;
import std.array: appender, empty, array, popBack, back;
import std.d.ast;
import std.d.lexer;
import std.file;
import std.path;
import std.stdio;
import std.string: format;
import std.typecons;
import unittest_preprocessor;
import writer;


/**
 * Generates documentation for a (single) module.
 */
class DocVisitor(Writer) : ASTVisitor
{
	/**
	 * Params:
	 *     config = Configuration data, including macros and the output directory.
	 *     unitTestMapping = The mapping of declaration addresses to their
	 *         documentation unittests
	 *     fileBytes = The source code of the module as a byte array.
	 *     writer = Handles writing into generated files.
	 */
	this(ref const Config config, TestRange[][size_t] unitTestMapping,
		const(ubyte[]) fileBytes, Writer writer)
	{
		this.config = &config;
		this.unitTestMapping = unitTestMapping;
		this.fileBytes = fileBytes;
		this.writer = writer;
	}

	/**
	 * Same as visit(const Module), but only determines the file (location) of the
	 * documentation, link to that file and module name, without actually writing the
	 * documentation.
	 *
	 * Returns: true if the module location was successfully determined, false if
	 *          there is no module declaration or the module is excluded from
	 *          generated documentation by the user.
	 */
	bool moduleInitLocation(const Module mod)
	{
		import std.range : chain, iota, join, only;
		import std.file : mkdirRecurse;
		import std.conv : to;

		if (mod.moduleDeclaration is null)
			return false;
		pushAttributes();
		stack = cast(string[]) mod.moduleDeclaration.moduleName.identifiers.map!(a => a.text).array;

		foreach(exclude; config.excludes)
		{
			// If module name is pkg1.pkg2.mod, we first check
			// "pkg1", then "pkg1.pkg2", then "pkg1.pkg2.mod"
			// i.e. we only check for full package/module names.
			if(iota(stack.length + 1).map!(l => stack[0 .. l].join(".")).canFind(exclude))
			{
				writeln("Excluded module ", stack.join("."));
				return false;
			}
		}

		baseLength = stack.length;
		moduleFileBase = stack.buildPath;
		link = moduleFileBase ~ ".html";


		const moduleFileBaseAbs = config.outputDirectory.buildPath(moduleFileBase);
		if (!exists(moduleFileBaseAbs))
			moduleFileBaseAbs.mkdirRecurse();
		const outputName = moduleFileBaseAbs ~ ".html";

		location = outputName;
		moduleName = to!string(stack.join("."));

		return true;
	}

	override void visit(const Module mod)
	{
		if(!moduleInitLocation(mod))
		{
			return;
		}

		File output = File(location, "w");
		scope(exit) output.close();

		auto fileWriter = output.lockingTextWriter;
		writer.writeHeader(fileWriter, moduleName, baseLength - 1);
		writer.writeTOC(fileWriter, moduleName);
		writer.writeBreadcrumbs(fileWriter, baseLength, stack);

		prevComments.length = 1;

		const comment = mod.moduleDeclaration.comment;
		if (comment !is null)
		{
			writer.readAndWriteComment(fileWriter, comment, prevComments,
				null, getUnittestDocTuple(mod.moduleDeclaration));
		}

		memberStack.length = 1;

		mod.accept(this);

		memberStack[$ - 1].write(fileWriter);

		fileWriter.put(HTML_END);
		fileWriter.put("\n");
	}

	override void visit(const EnumDeclaration ed)
	{
		enum formattingCode = q{
		fileWriter.put("enum " ~ ad.name.text);
		if (ad.type !is null)
		{
			fileWriter.put(" : ");
			formatter.format(ad.type);
		}
		};
		visitAggregateDeclaration!(formattingCode, "enums")(ed);
	}

	override void visit(const EnumMember member)
	{
		if (member.comment is null)
			return;
		auto dummy = appender!string();
		// No interest in detailed docs for an enum member.
		string summary = writer.readAndWriteComment(dummy, member.comment,
			prevComments, null, getUnittestDocTuple(member));
		memberStack[$ - 1].values ~= Item("#", member.name.text, summary);
	}

	override void visit(const ClassDeclaration cd)
	{
		enum formattingCode = q{
		fileWriter.put("class " ~ ad.name.text);
		if (ad.templateParameters !is null)
			formatter.format(ad.templateParameters);
		if (ad.baseClassList !is null)
			formatter.format(ad.baseClassList);
		if (ad.constraint !is null)
			formatter.format(ad.constraint);
		};
		visitAggregateDeclaration!(formattingCode, "classes")(cd);
	}

	override void visit(const TemplateDeclaration td)
	{
		enum formattingCode = q{
		fileWriter.put("template " ~ ad.name.text);
		if (ad.templateParameters !is null)
			formatter.format(ad.templateParameters);
		if (ad.constraint)
			formatter.format(ad.constraint);
		};
		visitAggregateDeclaration!(formattingCode, "templates")(td);
	}

	override void visit(const StructDeclaration sd)
	{
		enum formattingCode = q{
		fileWriter.put("struct " ~ ad.name.text);
		if (ad.templateParameters)
			formatter.format(ad.templateParameters);
		if (ad.constraint)
			formatter.format(ad.constraint);
		};
		visitAggregateDeclaration!(formattingCode, "structs")(sd);
	}

	override void visit(const InterfaceDeclaration id)
	{
		enum formattingCode = q{
		fileWriter.put("interface " ~ ad.name.text);
		if (ad.templateParameters !is null)
			formatter.format(ad.templateParameters);
		if (ad.baseClassList !is null)
			formatter.format(ad.baseClassList);
		if (ad.constraint !is null)
			formatter.format(ad.constraint);
		};
		visitAggregateDeclaration!(formattingCode, "interfaces")(id);
	}

	override void visit(const AliasDeclaration ad)
	{
		import std.path : dirSeparator;
		if (ad.comment is null)
			return;
		bool first;
		if (ad.identifierList !is null) foreach (name; ad.identifierList.identifiers)
		{
			string link;
			auto fileWriter = pushSymbol(name.text, first, link);
			scope(exit) popSymbol(fileWriter);

			writer.writeBreadcrumbs(fileWriter, baseLength, stack);

			string type = writeAliasType(fileWriter, name.text, ad.type);
			string summary = writer.readAndWriteComment(fileWriter, ad.comment, prevComments);
			memberStack[$ - 2].aliases ~= Item(link, name.text, summary, type);
		}
		else foreach (initializer; ad.initializers)
		{
			string link;
			auto fileWriter = pushSymbol(initializer.name.text, first, link);
			scope(exit) popSymbol(fileWriter);

			writer.writeBreadcrumbs(fileWriter, baseLength, stack);

			string type = writeAliasType(fileWriter, initializer.name.text, initializer.type);
			string summary = writer.readAndWriteComment(fileWriter, ad.comment, prevComments);
			memberStack[$ - 2].aliases ~= Item(link, initializer.name.text, summary, type);
		}
	}

	override void visit(const VariableDeclaration vd)
	{
		bool first;
		foreach (const Declarator dec; vd.declarators)
		{
			if (vd.comment is null && dec.comment is null)
				continue;
			string link;
			auto fileWriter = pushSymbol(dec.name.text, first, link);
			scope(exit) popSymbol(fileWriter);

			writer.writeBreadcrumbs(fileWriter, baseLength, stack);

			string summary = writer.readAndWriteComment(fileWriter,
				dec.comment is null ? vd.comment : dec.comment,
				prevComments);
			memberStack[$ - 2].variables ~= Item(link, dec.name.text, summary, writer.formatNode(vd.type));
		}
		if (vd.comment !is null && vd.autoDeclaration !is null) foreach (ident; vd.autoDeclaration.identifiers)
		{
			string link;
			auto fileWriter = pushSymbol(ident.text, first, link);
			scope(exit) popSymbol(fileWriter);

			writer.writeBreadcrumbs(fileWriter, baseLength, stack);

			string summary = writer.readAndWriteComment(fileWriter, vd.comment, prevComments);
			// TODO this was hastily updated to get harbored-mod to compile
			// after a libdparse update. Revisit and validate/fix any errors.
			string[] storageClasses;
			foreach(stor; vd.storageClasses)
			{
				storageClasses ~= str(stor.token.type);
			}
			auto i = Item(link, ident.text, summary, storageClasses.canFind("enum") ? null : "auto");
			if (storageClasses.canFind("enum"))
				memberStack[$ - 2].enums ~= i;
			else
				memberStack[$ - 2].variables ~= i;

			// string storageClass;
			// foreach (attr; vd.attributes)
			// {
			// 	if (attr.storageClass !is null)
			// 		storageClass = str(attr.storageClass.token.type);
			// }
			// auto i = Item(name, ident.text,
			// 	summary, storageClass == "enum" ? null : "auto");
			// if (storageClass == "enum")
			// 	memberStack[$ - 2].enums ~= i;
			// else
			// 	memberStack[$ - 2].variables ~= i;
		}
	}

	override void visit(const StructBody sb)
	{
		pushAttributes();
		sb.accept(this);
		popAttributes();
	}

	override void visit(const BlockStatement bs)
	{
		pushAttributes();
		bs.accept(this);
		popAttributes();
	}

	override void visit(const Declaration dec)
	{
		attributes[$ - 1] ~= dec.attributes;
		dec.accept(this);
		if (dec.attributeDeclaration is null)
			attributes[$ - 1] = attributes[$ - 1][0 .. $ - dec.attributes.length];
	}

	override void visit(const AttributeDeclaration dec)
	{
		attributes[$ - 1] ~= dec.attribute;
	}

	override void visit(const Constructor cons)
	{
		if (cons.comment is null)
			return;
		writeFnDocumentation("this", cons, attributes.back);
	}

	override void visit(const FunctionDeclaration fd)
	{
		if (fd.comment is null)
			return;
		writeFnDocumentation(fd.name.text, fd, attributes.back);
	}

	alias visit = ASTVisitor.visit;

	/// The module name in "package.package.module" format.
	string moduleName;

	/// The path to the HTML file that was generated for the module being
	/// processed.
	string location;

	/// Path to the HTML file relative to the output directory.
	string link;


private:
	void visitAggregateDeclaration(string formattingCode, string name, A)(const A ad)
	{
		bool first;
		if (ad.comment is null)
			return;

		string link;
		auto fileWriter = pushSymbol(ad.name.text, first, link);
		scope(exit) popSymbol(fileWriter, Yes.overloadable);

		if (first)
		{
			writer.writeBreadcrumbs(fileWriter, baseLength, stack);
		}
		else
		{
			fileWriter.put("<hr/>");
		}

		writer.writeCodeBlock(fileWriter, 
		{
			auto formatter = new HarboredFormatter!(typeof(fileWriter))(fileWriter);
			scope(exit) destroy(formatter.sink);
			assert(attributes.length > 0,
				"Attributes stack must not be empty when writing aggregate attributes");
			writer.writeAttributes(fileWriter, formatter, attributes.back);
			mixin(formattingCode);
		});

		string summary = writer.readAndWriteComment(fileWriter, ad.comment, prevComments,
			null, getUnittestDocTuple(ad));
		mixin(`memberStack[$ - 2].` ~ name ~ ` ~= Item(link, ad.name.text, summary);`);
		prevComments.length = prevComments.length + 1;
		ad.accept(this);
		prevComments.popBack();
		memberStack[$ - 1].write(fileWriter);
	}

	/**
	 * Params:
	 *     t = The declaration.
	 * Returns: An array of tuples where the first item is the contents of the
	 *     unittest block and the second item is the doc comment for the
	 *     unittest block. This array may be empty.
	 */
	Tuple!(string, string)[] getUnittestDocTuple(T)(const T t)
	{
		immutable size_t index = cast(size_t) (cast(void*) t);
//		writeln("Searching for unittest associated with ", index);
		auto tupArray = index in unitTestMapping;
		if (tupArray is null)
			return [];
//		writeln("Found a doc unit test for ", cast(size_t) &t);
		Tuple!(string, string)[] rVal;
		foreach (tup; *tupArray)
			rVal ~= tuple(cast(string) fileBytes[tup[0] + 2 .. tup[1]], tup[2]);
		return rVal;
	}

	/**
	 *
	 */
	void writeFnDocumentation(Fn)(string name, Fn fn, const(Attribute)[] attrs)
	{
		bool first;
		string fileRelative;
		auto fileWriter = pushSymbol(name, first, fileRelative);
		scope(exit) popSymbol(fileWriter, Yes.overloadable);

		// Stuff above the function doc
		if (first)
		{
			writer.writeBreadcrumbs(fileWriter, baseLength, stack);
		}
		else
		{
			fileWriter.put("<hr/>");
		}

		auto formatter = new HarboredFormatter!(typeof(fileWriter))(fileWriter);
		scope(exit) destroy(formatter.sink);

		// Write the function signature.
		writer.writeCodeBlock(fileWriter,

		{
			assert(attributes.length > 0,
				"Attributes stack must not be empty when writing function attributes");
			// Attributes like public, etc.
			writer.writeAttributes(fileWriter, formatter, attrs);
			// Return type and function name, with special case fo constructor
			static if (__traits(hasMember, typeof(fn), "returnType"))
			{
				if (fn.returnType)
				{
					formatter.format(fn.returnType);
					fileWriter.put(" ");
				}
				formatter.format(fn.name);
			}
			else
			{
				fileWriter.put("this");
			}
			// Template params
			if (fn.templateParameters !is null)
				formatter.format(fn.templateParameters);
			// Function params
			if (fn.parameters !is null)
				formatter.format(fn.parameters);
			// Attributes like const, nothrow, etc.
			foreach (a; fn.memberFunctionAttributes)
			{
				fileWriter.put(" ");
				formatter.format(a);
			}
			// Template constraint
			if (fn.constraint)
			{
				fileWriter.put(" ");
				formatter.format(fn.constraint);
			}
		});

		string summary = writer.readAndWriteComment(fileWriter, fn.comment,
			prevComments, fn.functionBody, getUnittestDocTuple(fn));
		string fdName;
		static if (__traits(hasMember, typeof(fn), "name"))
			fdName = fn.name.text;
		else
			fdName = "this";
		auto fnItem = Item(fileRelative, fdName, summary, null, fn);
		memberStack[$ - 2].functions ~= fnItem;
		prevComments.length = prevComments.length + 1;
		fn.accept(this);

		// The function may have nested functions/classes/etc, so at the very
		// least we need to close their files, and once public/private works even
		// document them.
		memberStack[$ - 1].write(fileWriter);
		prevComments.popBack();
	}

	/**
	 * Writes an alias' type to the given file and returns it.
	 * Params:
	 *     f = The file to write to
	 *     name = the name of the alias
	 *     t = the aliased type
	 * Returns: A string reperesentation of the given type.
	 */
	string writeAliasType(R)(ref R dst, string name, const Type t)
	{
		if (t is null)
			return null;
		string formatted = writer.formatNode(t);
		writer.writeCodeBlock(dst,
		{
			dst.put("alias %s = ".format(name));
			dst.put(formatted);
		});
		return formatted;
	}

	/**
	 * Params:
	 *
	 * name  = The symbol's name
	 * first = True if this is the first time that pushSymbol has been called for this name.
	 * link  = Link to the file where this symbol is documented in config.outputDirectory.
	 *
	 * Returns: A range to write the symbol's documentation to.
	 */
	auto pushSymbol(string name, ref bool first, ref string link)
	{
		import std.array : array, join;
		import std.string : format;
		stack ~= name;
		memberStack.length = memberStack.length + 1;
		// Path relative to output directory
		string classDocFileName = moduleFileBase.buildPath(
			"%s.html".format(stack[baseLength .. $].join(".").array));

		writer.addSearchEntry(moduleFileBase, baseLength, stack);
		immutable size_t i = memberStack.length - 2;
		assert (i < memberStack.length, "%s %s".format(i, memberStack.length));
		auto p = classDocFileName in memberStack[i].overloadFiles;
		first = p is null;
		link = classDocFileName;
		if (first)
		{
			first = true;
			auto f = File(config.outputDirectory.buildPath(classDocFileName), "w");
			memberStack[i].overloadFiles[classDocFileName] = f;

			auto fileWriter = f.lockingTextWriter;
			writer.writeHeader(fileWriter, name, baseLength);
			writer.writeTOC(fileWriter, moduleName);
			return f.lockingTextWriter;
		}
		else
			return p.lockingTextWriter;
	}

	void popSymbol(R)(ref R dst, Flag!"overloadable" overloadable = No.overloadable)
	{
		// If a symbol overloadable, it may still have some more overloads to
		// write in the current file so don't end it yet
		if(!overloadable)
		{
			dst.put(HTML_END);
			dst.put("\n");
		}
		stack.popBack();
		assert(memberStack[$ - 1].overloadFiles.length == 0,
		       "Files left open before popping symbol");
		memberStack.popBack();
	}

	void pushAttributes()
	{
		attributes.length = attributes.length + 1;
	}

	void popAttributes()
	{
		attributes.popBack();
	}

	const(Attribute)[][] attributes;
	Comment[] prevComments;
	/* Length, or nest level, of the module name.
	 *
	 * `mod` has baseLength, `pkg.mod` has baseLength 2, `pkg.child.mod` has 3, etc.
	 */
	size_t baseLength;
	string moduleFileBase;
	/** Namespace stack of the current symbol,
	 *
	 * E.g. ["package", "subpackage", "module", "Class", "member"]
	 */
	string[] stack;
	/** Every item of this stack corresponds to a parent module/class/etc of the
	 * current symbol, but not package.
	 *
	 * Each Members struct is used to accumulate all members of that module/class/etc
	 * so the list of all members can be generated.
	 */
	Members[] memberStack;
	TestRange[][size_t] unitTestMapping;
	const(ubyte[]) fileBytes;
	const(Config)* config;
	Writer writer;
}


enum HTML_END = `
<script>hljs.initHighlightingOnLoad();</script>
</div>
</div>
</body>
</html>`;

struct Item
{
	string url;
	string name;
	string summary;
	string type;

	/// AST node of the item. Only used for functions at the moment.
	const ASTNode node;

	void write(R)(ref R dst)
	{
		dst.put(`<tr><td>`);
		void writeName()
		{
			dst.put(url == "#" ? name : `<a href="%s">%s</a>`.format(url, name));
		}

		// TODO print attributes for everything, and move it to separate function/s
		if(cast(FunctionDeclaration) node) with(cast(FunctionDeclaration) node)
		{
			// extremely inefficient, rewrite if too much slowdown
			string formatAttrib(T)(T attr)
			{
				auto writer = appender!(char[])();
				auto formatter = new HarboredFormatter!(typeof(writer))(writer);
				formatter.format(attr);
				auto str = writer.data.idup;
				writer.clear();
				import std.ascii: isAlpha;
				import std.conv: to;
				// Sanitize CSS class name for the attribute,
				auto strSane = str.filter!isAlpha.array.to!string;
				return `<span class="attr-` ~ strSane ~ `">` ~ str ~ `</span>`;
			}

			void writeSpan(C)(string class_, C content)
			{
				dst.put(`<span class="%s">%s</span>`.format(class_, content));
			}

			// Above the function name
			if(!attributes.empty)
			{
				dst.put(`<span class="extrainfo">`);
				writeSpan("attribs", attributes.map!(a => formatAttrib(a)).joiner(", "));
				dst.put(`</span>`);
			}


			// The actual function name
			writeName();


			// Below the function name
			dst.put(`<span class="extrainfo">`);
			if(!memberFunctionAttributes.empty)
			{
				writeSpan("method-attribs",
					memberFunctionAttributes.map!(a => formatAttrib(a)).joiner(", "));
			}
			// TODO storage classes don't seem to work. libdparse issue?
			if(!storageClasses.empty)
			{
				writeSpan("stor-classes", storageClasses.map!(a => formatAttrib(a)).joiner(", "));
			}
			dst.put(`</span>`);
		}
		else
		{
			writeName();
		}
		dst.put(`</td>`);

		dst.put(`<td>`);
		if (type !is null)
			dst.put(`<pre><code>%s</code></pre>`.format(type));
		dst.put(`</td><td>%s</td></tr>`.format(summary));
	}
}

struct Members
{
	File[string] overloadFiles;
	Item[] aliases;
	Item[] classes;
	Item[] enums;
	Item[] functions;
	Item[] interfaces;
	Item[] structs;
	Item[] templates;
	Item[] values;
	Item[] variables;

	/// Write the table of members for a class/struct/module/etc.
	void write(R)(ref R dst)
	{
		if (aliases.length == 0 && classes.length == 0 && enums.length == 0
			&& functions.length == 0 && interfaces.length == 0
			&& structs.length == 0 && templates.length == 0 && values.length == 0
			&& variables.length == 0)
		{
			return;
		}
		dst.put(`<div class="section">`);
		if (enums.length > 0)
			write(dst, enums, "Enums");
		if (aliases.length > 0)
			write(dst, aliases, "Aliases");
		if (variables.length > 0)
			write(dst, variables, "Variables");
		if (functions.length > 0)
			write(dst, functions, "Functions");
		if (structs.length > 0)
			write(dst, structs, "Structs");
		if (interfaces.length > 0)
			write(dst, interfaces, "Interfaces");
		if (classes.length > 0)
			write(dst, classes, "Classes");
		if (templates.length > 0)
			write(dst, templates, "Templates");
		if (values.length > 0)
			write(dst, values, "Values");
		dst.put(`</div>`);
		foreach (f; overloadFiles)
		{
			f.writeln(HTML_END);
			f.close();
		}
		destroy(overloadFiles);
		assert(overloadFiles.length == 0, "Just checking");
	}

private:
	/** Write a table of items in category specified 
	 *
	 * Params:
	 *
	 * dst   = Range to write to.
	 * items = Items the table will contain.
	 * name  = Name of the table, used in heading, i.e. category of the items. E.g.
	 *         "Functions" or "Variables" or "Structs".
	 */
	void write(R)(ref R dst, Item[] items, string name)
	{
		dst.put("<h2>%s</h2>".format(name));
		dst.put(`<table>`);
		foreach (ref i; items)
			i.write(dst);
		dst.put(`</table>`);
	}
}
