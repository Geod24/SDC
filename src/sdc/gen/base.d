/**
 * Copyright 2010 Bernard Helyer
 * This file is part of SDC. SDC is licensed under the GPL.
 * See LICENCE or sdc.d for more details.
 */
module sdc.gen.base;

import std.conv;
import std.stdio;
import std.string;

import sdc.util;
import sdc.primitive;
import sdc.compilererror;
import sdc.ast.all;
import sdc.ast.declaration;
import sdc.extract.base;
import sdc.extract.expression;
import sdc.gen.expression;
import sdc.gen.semantic;
import sdc.gen.attribute;
public import asmgen = sdc.gen.llvm.base;


void genModule(Module mod, File file)
{
    auto semantic = new Semantic();
    asmgen.emitComment(file, extractQualifiedName(mod.moduleDeclaration.name));
    foreach (declarationDefinition; mod.declarationDefinitions) {
        genDeclarationDefinition(declarationDefinition, file, semantic);
    }
}


void genDeclarationDefinition(DeclarationDefinition declDef, File file, Semantic semantic)
{
    switch (declDef.type) {
    case DeclarationDefinitionType.Declaration:
        return genDeclaration(cast(Declaration) declDef.node, file, semantic);
    case DeclarationDefinitionType.AttributeSpecifier:
        return genAttributeSpecifier(cast(AttributeSpecifier) declDef.node, file, semantic);
    default:
        error(declDef.location, "unhandled DeclarationDefinition");
        assert(false);
    }
    assert(false);
}

void genAttributeSpecifier(AttributeSpecifier attributeSpecifier, File file, Semantic semantic)
{
    genAttribute(attributeSpecifier.attribute, file, semantic);
    if (attributeSpecifier.declarationBlock !is null) {
        genDeclarationBlock(attributeSpecifier.declarationBlock, file, semantic);
        semantic.popAttribute();
    }  // Otherwise, the attribute applies until the module's end.
}

void genDeclarationBlock(DeclarationBlock declarationBlock, File file, Semantic semantic)
{
    foreach (declarationDefinition; declarationBlock.declarationDefinitions) {
        genDeclarationDefinition(declarationDefinition, file, semantic);
    }
}

void genDeclaration(Declaration declaration, File file, Semantic semantic)
{
    if (declaration.type == DeclarationType.Function) {
        genFunctionDeclaration(cast(FunctionDeclaration) declaration.node, file, semantic);
    } else if (declaration.type == DeclarationType.Variable) {
        genVariableDeclaration(cast(VariableDeclaration) declaration.node, file, semantic);
    }
}

void genVariableDeclaration(VariableDeclaration declaration, File file, Semantic semantic)
{
    bool global = semantic.currentScope is semantic.globalScope;
    
    auto primitive = fullTypeToPrimitive(declaration.type);
    foreach (declarator; declaration.declarators) {
        auto name = extractIdentifier(declarator.name);
        auto syn = new SyntheticVariableDeclaration();
        syn.location = declaration.location;
        syn.type = declaration.type;
        syn.identifier = declarator.name;
        syn.initialiser = declarator.initialiser;
        try {
            semantic.addDeclaration(name, syn, global);
        } catch (RedeclarationError) {
            error(declarator.location, format("'%s' is already defined", name));
        }
        auto var = new Variable(name, primitive);
        if (!global) {
            asmgen.emitAlloca(file, var);
        } else {
            asmgen.emitGlobal(file, var);
        }
        
        if (syn.initialiser !is null) {
            genInitialiser(syn.initialiser, file, semantic, var);
        } else {
            genDefaultInitialiser(file, semantic, var);
        }
        syn.variable = var;
    }
}

void genInitialiser(Initialiser initialiser, File file, Semantic semantic, Variable var)
{
    if (initialiser.type == InitialiserType.Void) {
        return;
    }
    
    auto expr = genAssignExpression(cast(AssignExpression) initialiser.node, file, semantic);
    auto init = genVariable(removePointer(expr.primitive), "initialiser");
    asmgen.emitLoad(file, init, expr);
    asmgen.emitStore(file, var, init);
}

void genDefaultInitialiser(File file, Semantic semantic, Variable var)
{
    return asmgen.emitStore(file, var, new Constant("0", removePointer(var.primitive)));
}

void genFunctionDeclaration(FunctionDeclaration declaration, File file, Semantic semantic)
{
    asmgen.emitFunctionName(file, declaration);
    
    string functionName = extractIdentifier(declaration.name);
    semantic.addDeclaration(functionName, declaration);
    semantic.pushScope();
    foreach (i, parameter; declaration.parameters) if (parameter.identifier !is null) {
        auto var = new SyntheticVariableDeclaration();
        var.location = parameter.location;
        var.type = parameter.type;
        var.identifier = parameter.identifier;
        var.isParameter = true;
        semantic.addDeclaration(extractIdentifier(var.identifier), var);
        asmgen.emitFunctionParameter(file, fullTypeToPrimitive(var.type), extractIdentifier(var.identifier), i == declaration.parameters.length - 1);
    }
    asmgen.emitFunctionBeginEnd(file);
    asmgen.incrementIndent();
    genBlockStatement(declaration.functionBody.statement, file, semantic);
    if (!semantic.currentScope.hasReturnStatement) {
        asmgen.emitVoidReturn(file);
    }
    
    semantic.popScope();
    asmgen.decrementIndent();
    asmgen.emitCloseFunctionDeclaration(file, declaration);
}


void genBlockStatement(BlockStatement statement, File file, Semantic semantic)
{
    foreach(sstatement; statement.statements) {
        genStatement(sstatement, file, semantic);
    }
}

void genStatement(Statement statement, File file, Semantic semantic)
{
    if (statement.type == StatementType.Empty) {
    } else if (statement.type == StatementType.NonEmpty) {
        genNonEmptyStatement(cast(NonEmptyStatement) statement.node, file, semantic);
    }
}

void genNonEmptyStatement(NonEmptyStatement statement, File file, Semantic semantic)
{
    switch (statement.type) {
    case NonEmptyStatementType.ExpressionStatement:
        genExpressionStatement(cast(ExpressionStatement) statement.node, file, semantic);
        break;
    case NonEmptyStatementType.DeclarationStatement:
        genDeclarationStatement(cast(DeclarationStatement) statement.node, file, semantic);
        break;
    case NonEmptyStatementType.ReturnStatement:
        genReturnStatement(cast(ReturnStatement) statement.node, file, semantic);
        break;
    default:
        break;
    }
}

void genExpressionStatement(ExpressionStatement statement, File file, Semantic semantic)
{
    auto expr = genExpression(statement.expression, file, semantic);
}

void genDeclarationStatement(DeclarationStatement statement, File file, Semantic semantic)
{
    genDeclaration(statement.declaration, file, semantic);
}

void genReturnStatement(ReturnStatement statement, File file, Semantic semantic)
{
    semantic.currentScope.hasReturnStatement = true;
    if (statement.expression !is null) {
        auto expr = genExpression(statement.expression, file, semantic);
        auto retval = genVariable(Primitive(expr.primitive.size, expr.primitive.pointer - 1), "retval");
        asmgen.emitLoad(file, retval, expr);
        asmgen.emitReturn(file, retval);
    } else {
        asmgen.emitVoidReturn(file);
    }
}

