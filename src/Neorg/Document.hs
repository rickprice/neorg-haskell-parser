{-# LANGUAGE TemplateHaskell #-}

module Neorg.Document where

import Data.Data (Proxy)
import qualified Data.Map as M
import Data.Maybe (isJust)
import Data.Text (pack)
import Data.Text as T (Text, unwords)
import Data.Time.Calendar (Day, showGregorian)
import qualified Data.Vector as V
import Data.Void (Void)
import GHC.TypeLits (KnownSymbol, Symbol, sameSymbol, symbolVal)
import Optics.TH (makeLenses)
import qualified Text.Megaparsec as P
import Type.Set (TypeSet)
import Unsafe.Coerce (unsafeCoerce)

newtype Document (tags :: TypeSet) = Document
  { _documentBlocks :: Blocks tags
  }
  deriving (Show, Eq)

data DocumentMeta = DocumentMeta
  { _documentTitle :: Maybe Text,
    _documentDescription :: Maybe Text,
    _documentAuthor :: Maybe Text,
    _documentCategories :: V.Vector Text,
    _documentCreated :: Maybe Day,
    _documentVersion :: Maybe Text
  }
  deriving (Show, Eq)

emptyDocumentMeta :: DocumentMeta
emptyDocumentMeta = DocumentMeta Nothing Nothing Nothing V.empty Nothing Nothing

data IndentationLevel = I0 | I1 | I2 | I3 | I4 | I5 deriving (Eq, Ord, Bounded, Show)

instance Enum IndentationLevel where
  toEnum 0 = I0
  toEnum 1 = I1
  toEnum 2 = I2
  toEnum 3 = I3
  toEnum 4 = I4
  toEnum 5 = I5
  toEnum x = if x < 0 then I0 else I5
  fromEnum I0 = 0
  fromEnum I1 = 1
  fromEnum I2 = 2
  fromEnum I3 = 3
  fromEnum I4 = 4
  fromEnum I5 = 5

indentationLevelToInt :: IndentationLevel -> Int
indentationLevelToInt = fromEnum

data Block (tags :: TypeSet)
  = Paragraph Inline
  | Heading Heading
  | Quote Quote
  | List List
  | Delimiter Delimiter
  | Marker Marker
  | Tag (SomeTag tags)
  deriving (Show, Eq)

-- Tag :: SomeTag tags -> Block

type Blocks tags = V.Vector (Block tags)

data Delimiter = HorizonalLine | WeakDelimiter | StrongDelimiter deriving (Show, Eq)

data Heading = HeadingCons
  { _headingText :: Inline,
    _headingLevel :: IndentationLevel
  }
  deriving (Show, Eq)

data ListBlock = ListParagraph Inline | SubList List deriving (Show, Eq)

type ListBlocks = V.Vector ListBlock

data Quote = QuoteCons
  { _quoteLevel :: IndentationLevel,
    _quoteContent :: Inline
  }
  deriving (Show, Eq)

data Marker = MarkerCons {_markerId :: Text, _markerText :: Text} deriving (Show, Eq)

--
-- data Definition = DefinitionCons
--   { _definitionObject :: Text,
--     _definitionContent ::  ???
--   }
--   deriving (Show, Eq)

--
-- listBlockToBlock :: ListBlock -> Block
-- listBlockToBlock (ListParagraph p) = Paragraph p
-- listBlockToBlock (SubList list) = List list

data UnorderedList = UnorderedListCons
  { _uListLevel :: IndentationLevel,
    _uListItems :: V.Vector (V.Vector ListBlock)
  }
  deriving (Show, Eq)

data OrderedList = OrderedListCons
  { _oListLevel :: IndentationLevel,
    _oListItems :: V.Vector (V.Vector ListBlock)
  }
  deriving (Show, Eq)

data TaskStatus = TaskDone | TaskPending | TaskUndone deriving (Show, Eq)

data TaskList = TaskListCons
  { _tListLevel :: IndentationLevel,
    _tListItems :: V.Vector (TaskStatus, V.Vector ListBlock)
  }
  deriving (Show, Eq)

data List = UnorderedList UnorderedList | OrderedList OrderedList | TaskList TaskList deriving (Show, Eq)

data Inline
  = Text Text
  | Bold Inline
  | Italic Inline
  | Underline Inline
  | Strikethrough Inline
  | Superscript Inline
  | Subscript Inline
  | Spoiler Inline
  | Verbatim Text
  | Math Text
  | ConcatInline (V.Vector Inline)
  | Link Text Inline
  | Space
  deriving (Show, Eq)

instance Semigroup Inline where
  i1 <> i2 = ConcatInline $ V.fromList [i1, i2]

instance Monoid Inline where
  mempty = ConcatInline V.empty

canonalizeInline :: Inline -> Inline
canonalizeInline = \case
  ConcatInline inlines ->
    let vector = V.fromList $ processInlinesV inlines
     in if V.length vector == 1
          then V.head vector
          else ConcatInline vector
  a -> a
  where
    processInlinesV = processInlines . V.toList
    processInlines :: [Inline] -> [Inline]
    processInlines = \case
      (Text t1 : x : r) -> case canonalizeInline x of
        (Text t2) -> processInlines $ Text (t1 <> t2) : r
        c -> Text t1 : processInlines (c : r)
      (Text t1 : r) -> Text t1 : processInlines r
      (ConcatInline is1 : r) -> processInlines $ V.toList is1 <> r
      (Bold i : r) -> Bold (canonalizeInline i) : processInlines r
      (Italic i : r) -> Italic (canonalizeInline i) : processInlines r
      (Underline i : r) -> Underline (canonalizeInline i) : processInlines r
      (Strikethrough i : r) -> Strikethrough (canonalizeInline i) : processInlines r
      (Superscript i : r) -> Superscript (canonalizeInline i) : processInlines r
      (Subscript i : r) -> Subscript (canonalizeInline i) : processInlines r
      (Spoiler i : r) -> Spoiler (canonalizeInline i) : processInlines r
      (Math t : r) -> Math t : processInlines r
      (Verbatim t : r) -> Verbatim t : processInlines r
      (Link t i : r) -> Link t (canonalizeInline i) : processInlines r
      (Space : r) -> Space : processInlines r
      [] -> []

type TagParser = P.Parsec Void Text

class (KnownSymbol a, Eq (TagArguments a), Eq (TagContent a), Show (TagArguments a), Show (TagContent a)) => Tag (a :: Symbol) where
  type TagArguments a
  type TagContent a

class Tag a => ParseTagContent (a :: Symbol) where
  parseTagContent :: f a -> TagArguments a -> TagParser (TagContent a)

data SomeTag (tags :: TypeSet) where
  SomeTag :: Tag t => Proxy t -> TagArguments t -> TagContent t -> SomeTag tags

instance Show (SomeTag tags) where
  show (SomeTag tag args content) = show (symbolVal tag, args, content)

instance Eq (SomeTag tags) where
  (SomeTag p1 args1 content1) == (SomeTag p2 args2 content2) =
    isJust (p1 `sameSymbol` p2) && args1 == unsafeCoerce args2 && content1 == unsafeCoerce content2

instance Tag "code" where
  type TagArguments "code" = Maybe Text
  type TagContent "code" = Text

instance Tag "math" where
  type TagArguments "math" = ()
  type TagContent "math" = Text

instance Tag "comment" where
  type TagArguments "comment" = ()
  type TagContent "comment" = Text

instance Tag "embed" where
  type TagArguments "embed" = Text
  type TagContent "embed" = Text

instance Tag "document.meta" where
  type TagArguments "document.meta" = ()
  type TagContent "document.meta" = DocumentMeta

instance Tag "table" where
  type TagArguments "table" = ()
  type TagContent "table" = Table

newtype Table = Table (V.Vector TableRow) deriving (Show, Eq)

data TableRow = TableRowDelimiter | TableRowInlines (V.Vector Inline) deriving (Show, Eq)

instance Tag "ordered" where
  type TagArguments "ordered" = (Maybe Int, Maybe Int, Maybe Int)
  type TagContent "ordered" = OrderedList

makeLenses ''Document
makeLenses ''DocumentMeta
makeLenses ''Heading
makeLenses ''Quote
makeLenses ''Marker
makeLenses ''UnorderedList
makeLenses ''OrderedList
makeLenses ''TaskList
