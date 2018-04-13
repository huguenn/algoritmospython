{-# LANGUAGE DataKinds, RankNTypes, TypeOperators #-}
module Language.Java.Assignment
( assignment
, Syntax
, Grammar
, Term
) where

import Assigning.Assignment hiding (Assignment, Error)
import Data.Abstract.FreeVariables
import Data.Functor (void, ($>))
import Data.List.NonEmpty (some1)
import Data.Record
import Data.Semigroup
import Data.Syntax (contextualize, emptyTerm, handleError, infixContext, makeTerm, makeTerm', makeTerm'', makeTerm1, parseError, postContextualize)
import Data.Union
import GHC.Stack
import Language.Java.Grammar as Grammar
import Language.Java.Syntax as Java.Syntax
import qualified Assigning.Assignment as Assignment
import qualified Data.Syntax as Syntax
import qualified Data.Syntax.Comment as Comment
import qualified Data.Syntax.Declaration as Declaration
import qualified Data.Syntax.Expression as Expression
import qualified Data.Syntax.Literal as Literal
import qualified Data.Syntax.Statement as Statement
import qualified Data.Syntax.Type as Type
import qualified Data.Term as Term

type Syntax =
  '[ Comment.Comment
   , Declaration.Class
   , Declaration.InterfaceDeclaration
   , Declaration.Method
   , Declaration.VariableDeclaration
   , Java.Syntax.ArrayType
   , Java.Syntax.Import
   , Java.Syntax.Module
   , Java.Syntax.Package
   , Literal.Array
   , Literal.Boolean
   , Literal.Integer
   , Literal.Float
   , Literal.Null
   , Literal.String
   , Literal.TextElement
   , Statement.Assignment
   , Syntax.Context
   , Syntax.Empty
   , Syntax.Error
   , Syntax.Identifier
   , Syntax.AccessibilityModifier
   , Syntax.Program
   , Type.Bool
   , Type.Int
   , Type.Void
   , Type.Float
   , Type.Annotation
   , Statement.Return
   , []
   ]

type Term = Term.Term (Union Syntax) (Record Location)
type Assignment = HasCallStack => Assignment.Assignment [] Grammar Term

-- | Assignment from AST in Java's grammar onto a program in Java's syntax.
assignment :: Assignment
assignment = handleError $ makeTerm <$> symbol Grammar.Program <*> children (Syntax.Program <$> manyTerm expression) <|> parseError

-- | Match a term optionally preceded by comment(s), or a sequence of comments if the term is not present.
manyTerm :: Assignment -> Assignment.Assignment [] Grammar [Term]
manyTerm term = many (contextualize comment term <|> makeTerm1 <$> (Syntax.Context <$> some1 comment <*> emptyTerm))

someTerm :: Assignment -> Assignment.Assignment [] Grammar [Term]
someTerm term = some (contextualize comment term <|> makeTerm1 <$> (Syntax.Context <$> some1 comment <*> emptyTerm))

term :: Assignment -> Assignment
term term = contextualize comment (postContextualize comment term)

expression :: Assignment
expression = handleError (choice expressionChoices)

expressions :: Assignment
expressions = makeTerm'' <$> location <*> many expression

expressionChoices :: [Assignment.Assignment [] Grammar Term]
expressionChoices =
  [
    arrayInitializer
  , char
  , class'
  -- , constantDeclaration
  , float
  -- , hexadecimal
  , interface
  , identifier
  , import'
  , integer
  , method
  , module'
  , null'
  , package
  , return'
  , string
  , localVariableDeclaration
  , localVariableDeclarationStatement
  ]

modifier :: Assignment
modifier = makeTerm <$> symbol Modifier <*> (Syntax.AccessibilityModifier <$> source)

arrayInitializer :: Assignment
arrayInitializer = makeTerm <$> symbol ArrayInitializer <*> (Literal.Array <$> many expression)

comment :: Assignment
comment = makeTerm <$> symbol Comment <*> (Comment.Comment <$> source)

-- constantDeclaration :: Assignment
-- constantDeclaration = makeTerm <$> symbol ConstantDeclaration <*>

localVariableDeclaration :: Assignment
localVariableDeclaration = makeDecl <$> symbol LocalVariableDeclaration <*> children ((,) <$> some type' <*> vDeclList)
  where
    makeSingleDecl loc types (target, value) = makeTerm loc (Statement.Assignment types target value)
    makeDecl loc (types, decls) = makeTerm loc $ fmap (makeSingleDecl loc types) decls
    vDeclList = symbol VariableDeclaratorList *> children (some variableDeclarator)
    variableDeclarator = symbol VariableDeclarator *> children ((,) <$> variable_declarator_id <*> expression)

localVariableDeclarationStatement :: Assignment
localVariableDeclarationStatement = symbol LocalVariableDeclarationStatement *> children localVariableDeclaration

unannotatedType :: Assignment
unannotatedType = makeTerm <$> symbol Grammar.ArrayType <*> (Java.Syntax.ArrayType <$> source)

variable_declarator_id :: Assignment
variable_declarator_id = symbol VariableDeclaratorId *> children identifier

-- Literals

-- TODO: Need to disaggregate true/false in treesitter
boolean :: Assignment
boolean = makeTerm <$> token BooleanLiteral <*> pure Literal.true

-- boolean :: Assignment
-- boolean =  makeTerm <$> token Grammar.True <*> pure Literal.true
--        <|> makeTerm <$> token Grammar.False <*> pure Literal.false

null' :: Assignment
null' = makeTerm <$> symbol NullLiteral <*> (Literal.Null <$ source)
-- why is this <$?

-- Supports all integer and floating point literals (hex, octal, binary)
integer :: Assignment
integer = makeTerm <$> symbol IntegerLiteral <*> children (Literal.Integer <$> source)

float :: Assignment
float = makeTerm <$> symbol FloatingPointLiteral <*> children (Literal.Float <$> source)

string :: Assignment
string = makeTerm <$> symbol StringLiteral <*> (Literal.TextElement <$> source)

char :: Assignment
char = makeTerm <$> symbol CharacterLiteral <*> (Literal.TextElement <$> source)

class' :: Assignment
class' = makeTerm <$> symbol ClassDeclaration <*> children (Declaration.Class <$> many modifier <*> term identifier <*> pure [] <*> classBody)
  where classBody = makeTerm <$> symbol ClassBody <*> children (manyTerm expression)

-- consolidated with scopedIdentifier
identifier :: Assignment
identifier = makeTerm <$> (symbol Identifier <|> symbol ScopedIdentifier) <*> (Syntax.Identifier . name <$> source)

method :: Assignment
method = makeTerm <$> symbol MethodDeclaration <*> children (
             (makeMethod <$> many modifier <* symbol MethodHeader <*> emptyTerm <*> children ((,) <$> type' <* symbol MethodDeclarator <*> children ( (,) <$> identifier <*> manyTerm parameter)) )
          <* symbol MethodBody <*> children (makeTerm <$> symbol Block <*> children (manyTerm expression))
          )
  where makeMethod modifiers receiver (returnType, (name, params)) body = Declaration.Method (returnType : modifiers) receiver name params body
        parameter = makeTerm <$> symbol FormalParameter <*> children (flip Type.Annotation <$> type' <* symbol VariableDeclaratorId <*> children identifier)
-- TODO: re-introduce makeTerm later; matching types as part of the type rule for now.

module' :: Assignment
module' = makeTerm <$> symbol ModuleDeclaration <*> children (Java.Syntax.Module <$> expression <*> many expression)

import' :: Assignment
import' = makeTerm <$> symbol ImportDeclaration <*> children (Java.Syntax.Import <$> some identifier)

interface :: Assignment
interface = makeTerm <$> symbol InterfaceDeclaration <*> children (normal <|> annotationType)
  where
    interfaceBody = makeTerm <$> symbol InterfaceBody <*> children (many expression)
    normal = symbol NormalInterfaceDeclaration *> children (Declaration.InterfaceDeclaration [] <$> identifier <*> interfaceBody)
    annotationType = symbol AnnotationTypeDeclaration *> children (Declaration.InterfaceDeclaration [] <$> identifier <*> annotationTypeBody)
    annotationTypeBody = makeTerm <$> symbol AnnotationTypeBody <*> children (many expression)

package :: Assignment
package = makeTerm <$> symbol PackageDeclaration <*> children (Java.Syntax.Package <$> some identifier)

return' :: Assignment
return' = makeTerm <$> symbol ReturnStatement <*> children (Statement.Return <$> expression)

type' :: Assignment
type' =   makeTerm <$> token VoidType <*> pure Type.Void
     <|>  makeTerm <$> token IntegralType <*> pure Type.Int
     <|>  makeTerm <$> token FloatingPointType <*> pure Type.Float
     <|>  makeTerm <$> token BooleanType <*> pure Type.Bool
     -- <|> makeTerm <$> symbol FloatingPointType <*> children (token AnonFloat $> Type.Float <|> token AnonDouble $> Type.Double)

-- method expressions

-- TODO: consolidate ifthen  and ifthenelse in grammar
-- if' :: Assignment
-- if' = makeTerm <$> symbol Conditional <*> children (Statement.If <$> expression <*> expression <*> expression)
--
-- if' :: Assignment
-- if' = makeTerm <$> symbol IfThenStatement <*> children (Statement.If <$> expression <*> expression <*> (else' <|> emptyTerm))
--   <|> makeTerm
--
-- else' :: Assignment
-- else' = makeTerm <$> symbol IfThenElseStatement <*> children

-- from Ruby
-- if' :: Assignment
-- if' =   ifElsif If
--     <|> makeTerm <$> symbol IfModifier <*> children (flip Statement.If <$> expression <*> expression <*> emptyTerm)
--   where
--     ifElsif s = makeTerm <$> symbol s <*> children (Statement.If <$> expression <*> expressions' <*> (elsif' <|> else' <|> emptyTerm))
--     expressions' = makeTerm <$> location <*> manyTermsTill expression (void (symbol Else) <|> void (symbol Elsif) <|> eof)
--     elsif' = postContextualize comment (ifElsif Elsif)
--     else' = postContextualize comment (symbol Else *> children expressions)
--
-- for :: Assignment
-- for = makeTerm <$> symbol For <*> children (Statement.ForEach <$> (makeTerm <$> location <*> manyTermsTill expression (symbol In)) <*> inClause <*> expressions)
--   where inClause = symbol In *> children expression

-- expression

-- infix operators
-- binary :: Assignment
-- binary = makeTerm
