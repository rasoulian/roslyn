﻿' Copyright(c) Microsoft.  All Rights Reserved.  Licensed under the Apache License, Version 2.0.  See License.txt In the project root For license information

Imports System.Composition
Imports System.Threading
Imports Microsoft.CodeAnalysis.CodeRefactorings
Imports Microsoft.CodeAnalysis.ConvertAutoPropertyToFullProperty
Imports Microsoft.CodeAnalysis.Editing
Imports Microsoft.CodeAnalysis.VisualBasic.Syntax

Namespace Microsoft.CodeAnalysis.VisualBasic.VisualBasicConvertAutoPropertyToFullPropertyCodeRefactoringProvider
    <ExportCodeRefactoringProvider(LanguageNames.VisualBasic, Name:=NameOf(VisualBasicConvertAutoPropertyToFullPropertyCodeRefactoringProvider)), [Shared]>
    Friend Class VisualBasicConvertAutoPropertyToFullPropertyCodeRefactoringProvider
        Inherits AbstractConvertAutoPropertyToFullPropertyCodeRefactoringProvider

        Friend Overrides Function GetProperty(token As SyntaxToken) As SyntaxNode
            Dim containingProperty = token.Parent.FirstAncestorOrSelf(Of PropertyStatementSyntax)
            If (containingProperty Is Nothing) Then
                Return Nothing
            End If

            Dim start = If(containingProperty.AttributeLists.Count > 0,
                containingProperty.AttributeLists.Last().GetLastToken().GetNextToken().SpanStart,
                containingProperty.SpanStart)

            ' Offer this refactoring anywhere in the signature of the property.
            Dim position = token.SpanStart
            If (position < start) Then
                Return Nothing
            End If

            If containingProperty.HasReturnType() AndAlso
                position > containingProperty.GetReturnType().Span.End Then
                Return Nothing
            End If

            Return containingProperty
        End Function

        Friend Overrides Function GetNewAccessorsAsync(
                document As Document,
                propertyNode As SyntaxNode,
                fieldName As String,
                generator As SyntaxGenerator,
                cancellationToken As CancellationToken) As Task(Of (newGetAccessor As SyntaxNode, newSetAccessor As SyntaxNode))

            Dim returnStatement = New SyntaxList(Of StatementSyntax)(DirectCast(generator.ReturnStatement(generator.IdentifierName(fieldName)), StatementSyntax))
            Dim getAccessor As SyntaxNode = SyntaxFactory.GetAccessorBlock(
                    SyntaxFactory.GetAccessorStatement(),
                    returnStatement)

            Dim propertySyntax = DirectCast(propertyNode, PropertyStatementSyntax)

            Dim setAccessor As SyntaxNode
            If IsReadOnly(propertySyntax) Then
                setAccessor = Nothing
            Else
                Dim setStatement = New SyntaxList(Of StatementSyntax)(DirectCast(generator.ExpressionStatement(generator.AssignmentStatement(
                        generator.IdentifierName(fieldName),
                        generator.IdentifierName("Value"))), StatementSyntax))
                setAccessor = SyntaxFactory.SetAccessorBlock(
                        SyntaxFactory.SetAccessorStatement(),
                        setStatement)
            End If

            Return Task.FromResult((getAccessor, setAccessor))
        End Function

        Private Function IsReadOnly(propertySyntax As PropertyStatementSyntax) As Boolean

            Dim modifiers = propertySyntax.GetModifiers()
            For Each modifier In modifiers
                If modifier.IsKind(SyntaxKind.ReadOnlyKeyword) Then
                    Return True
                End If
            Next

            Return False
        End Function

        Friend Overrides Function GetUniqueName(fieldName As String, propertySymbol As IPropertySymbol) As String
            ' In VB, auto properties have a hidden backing field that is named using the property 
            ' name preceded by an underscore. If the parameter 'fieldName' is the same as this 
            ' hidden field, the NameGenerator.GenerateUniqueName method will incorrectly think 
            ' there is already a member with that name. So we need to check for that case first.
            If (String.Equals(fieldName.ToLower(), "_" & propertySymbol.Name.ToLower())) Then
                Return fieldName
            Else
                Return NameGenerator.GenerateUniqueName(fieldName, Function(n) propertySymbol.ContainingType.GetMembers(n).IsEmpty())
            End If
        End Function

        Friend Overrides Function GetTypeBlock(syntaxNode As SyntaxNode) As SyntaxNode
            Return DirectCast(syntaxNode, TypeStatementSyntax).Parent
        End Function

        Friend Overrides Function GetInitializerValue(propertyNode As SyntaxNode) As SyntaxNode
            Return DirectCast(propertyNode, PropertyStatementSyntax).Initializer?.Value
        End Function

        Friend Overrides Function GetPropertyWithoutInitializer(propertyNode As SyntaxNode) As SyntaxNode
            Return DirectCast(propertyNode, PropertyStatementSyntax).WithInitializer(Nothing)
        End Function
    End Class
End Namespace
