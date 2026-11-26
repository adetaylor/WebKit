//  Copyright (C) 1999-2001 Harri Porten (porten@kde.org)
//  Copyright (C) 2001 Peter Kelly (pmk@post.com)
//  Copyright (C) 2003-2024 Apple Inc. All rights reserved.
//  Copyright (C) 2026 Apple Inc. All rights reserved.
//
//  This library is free software; you can redistribute it and/or
//  modify it under the terms of the GNU Library General Public
//  License as published by the Free Software Foundation; either
//  version 2 of the License, or (at your option) any later version.
//
//  This library is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  Library General Public License for more details.
//
//  You should have received a copy of the GNU Library General Public License
//  along with this library; see the file COPYING.LIB.  If not, write to
//  the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
//  Boston, MA 02110-1301, USA.
//

internal import JSCSwiftBoundary

extension Parser {
    /// The parser state (with the builder's unary token stack depth) and the lexer's.
    mutating func createSavePoint<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) -> SavePoint {
        assert(!hasError)
        return SavePoint(
            parserState: parserState,
            unaryTokenStackDepth: context.unaryTokenStackDepth(&facade),
            lexerState: internalSaveLexerState()
        )
    }

    // If you're using this directly, you probably should be using
    // createSavePoint() instead.
    // i.e, if you parse any kind of AssignmentExpression between
    // saving/restoring, you should definitely not be using this directly.
    @inline(always)
    func internalSaveLexerState() -> LexerState {
        LexerState(
            startOffset: token.startPosition.offset,
            lastTokenLocation: lastTokenLocation,
            // Why is this reading from Lexer fine while we are re-lexing the same token?
            // This is because this flag is updated and indicating whether we have a line
            // terminator before the lexed token, and based on that, we already moved startOffset.
            hasLineTerminatorBeforeToken: lexer.hasLineTerminatorBeforeToken,
            lastTokenType: lastTokenType
        )
    }

    mutating func restoreLexerState(_ lexerState: LexerState, _ facade: inout JSC.JSParseFacade) {
        // setOffset clears lexer errors.
        lexer.restore(
            Lexer<Unit>
                .SavePoint(
                    offset: Int(lexerState.startOffset),
                    hasLineTerminatorBeforeToken: lexerState.hasLineTerminatorBeforeToken
                )
        )
        lastTokenType = lexerState.lastTokenType
        token.type = lexerState.lastTokenType
        token.startPosition.offset = Int32(bitPattern: lexerState.lastTokenLocation.startOffset)
        token.endPosition.offset = Int32(bitPattern: lexerState.lastTokenLocation.endOffset)
        nextWithoutClearingLineTerminator([], &facade)
    }

    mutating func restoreSavePoint<B: TreeBuilder>(_ context: inout B, _ savePoint: SavePoint, _ facade: inout JSC.JSParseFacade) {
        restoreLexerState(savePoint.lexerState, &facade)
        parserState = savePoint.parserState
        context.setUnaryTokenStackDepth(&facade, savePoint.unaryTokenStackDepth)
        errorMessage = nil
    }

    // If you're using this directly, you probably should be using
    // createSavePoint() instead.
    mutating func saveParserStateForFunction<B: TreeBuilder>(
        _ context: inout B,
        _ facade: inout JSC.JSParseFacade
    ) -> (parserState: ParserState, unaryTokenStackDepth: Int32) {
        (parserState, context.unaryTokenStackDepth(&facade))
    }

    mutating func restoreParserStateForFunction<B: TreeBuilder>(
        _ context: inout B,
        _ state: (parserState: ParserState, unaryTokenStackDepth: Int32),
        _ facade: inout JSC.JSParseFacade
    ) {
        parserState = state.parserState
        context.setUnaryTokenStackDepth(&facade, state.unaryTokenStackDepth)
    }

    mutating func lexCurrentTokenAgainUnderCurrentContext<B: TreeBuilder>(_ context: inout B, _ facade: inout JSC.JSParseFacade) {
        let savePoint = createSavePoint(&context, &facade)
        restoreSavePoint(&context, savePoint, &facade)
    }

    struct LexerState {
        var startOffset: Int32
        var lastTokenLocation: JSC.JSTokenLocation
        var hasLineTerminatorBeforeToken: Bool
        var lastTokenType: JSC.JSTokenType
    }

    struct SavePoint {
        var parserState: ParserState
        /// The builder's unary token stack depth, which the parser state does not hold.
        var unaryTokenStackDepth: Int32
        var lexerState: LexerState
    }

    /// A save point with the lexer's and the parser's pending errors.
    struct SavePointWithError {
        var savePoint: SavePoint
        var lexerError: Bool
        var lexerErrorMessage: LexerErrorMessage?
        var parserErrorMessage: ErrorMessage?
    }

    /// Saves the current state with its errors and restores oldSavePoint.
    mutating func swapSavePointForError<B: TreeBuilder>(
        _ context: inout B,
        _ oldSavePoint: SavePoint,
        _ facade: inout JSC.JSParseFacade
    ) -> SavePointWithError {
        // Not createSavePoint, which asserts that no error is pending.
        let result = SavePointWithError(
            savePoint: SavePoint(
                parserState: parserState,
                // Make sure we set our new savepoints unary stack to what oldSavePoint had as it currently may contain stale info.
                unaryTokenStackDepth: oldSavePoint.unaryTokenStackDepth,
                lexerState: internalSaveLexerState()
            ),
            lexerError: lexer.sawError,
            lexerErrorMessage: lexer.errorMessage,
            parserErrorMessage: errorMessage
        )
        restoreSavePoint(&context, oldSavePoint, &facade)
        return result
    }

    mutating func restoreSavePointWithError<B: TreeBuilder>(
        _ context: inout B,
        _ saved: SavePointWithError,
        _ facade: inout JSC.JSParseFacade
    ) {
        restoreSavePoint(&context, saved.savePoint, &facade)
        lexer.sawError = saved.lexerError
        lexer.errorMessage = saved.lexerErrorMessage
        errorMessage = saved.parserErrorMessage
    }
}
