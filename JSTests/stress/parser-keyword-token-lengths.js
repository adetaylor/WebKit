// Each keyword is lexed at the end of the source (fewer than the longest keyword's length of characters left) and
// in the middle of it, with and without a suffix that makes it an identifier.
const reserved = ["break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "new", "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "with"];
const strictReserved = ["implements", "interface", "package", "private", "protected", "public", "static", "let", "yield"];

// Enough characters after the word that the lexer sees the longest keyword's length of source left.
const tail = "\n;" + " ".repeat(11);

function check(source, ok) {
    checkOne(source, ok);
    checkOne(source + tail, ok);
}

function checkOne(source, ok) {
    let threw = false;
    try {
        eval(source);
    } catch (e) {
        if (!(e instanceof SyntaxError))
            throw new Error("not a SyntaxError for " + source + ": " + e);
        threw = true;
    }
    if (threw === ok)
        throw new Error("unexpected " + (ok ? "SyntaxError" : "success") + " for " + source);
}

for (const word of reserved) {
    check("var " + word, false);
    check("var " + word + "x", true);
    check("var x" + word, true);
    check("var " + word + "_", true);
    check("({" + word + ": 1})", true);
    check("({}). " + word, true);
    check("var o = {}; o." + word, true);
    check("var $" + word, true);
}
for (const word of strictReserved) {
    check("'use strict'; var " + word, false);
    check("'use strict'; var " + word + "x", true);
    check("'use strict'; var o = {}; o." + word, true);
    check("var " + word, true);
}

// await is reserved only where it is a keyword.
check("var await", true);
check("var awaitx", true);
check("var o = {}; o.await", true);
check("async function f() { var await }", false);
