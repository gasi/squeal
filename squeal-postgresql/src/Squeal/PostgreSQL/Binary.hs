{-|
Module: Squeal.PostgreSQL.Binary
Description: Binary encoding and decoding
Copyright: (c) Eitan Chatav, 2017
Maintainer: eitan@morphism.tech
Stability: experimental

This module provides binary encoding and decoding between Haskell and PostgreSQL types.

Instances are governed by the `SOP.Generic` and `SOP.HasDatatypeInfo` typeclasses, so you absolutely
do not need to define your own instances to decode retrieved rows into Haskell values or
to encode Haskell values into statement parameters.

Let's see some examples. We'll need some imports

>>> import Data.Int (Int16)
>>> import Data.Text (Text)
>>> import Control.Monad (void)
>>> import Control.Monad.Base (liftBase)
>>> import Squeal.PostgreSQL

Define a Haskell datatype @Row@ that will serve as both the input and output of a simple
round trip query.

>>> data Row = Row { col1 :: Int16, col2 :: Text, col3 :: Maybe Bool } deriving (Eq, GHC.Generic)
>>> instance Generic Row
>>> instance HasDatatypeInfo Row
>>> :{
let
  roundTrip :: Query_ (Public '[]) Row Row
  roundTrip = values_ $
    parameter @1 int2 `as` #col1 :*
    parameter @2 text `as` #col2 :*
    parameter @3 bool `as` #col3
:}

So long as we can encode the parameters and then decode the result of the query,
the input and output should be equal.

>>> let input = Row 2 "hi" (Just True)
>>> :{
void . withConnection "host=localhost port=5432 dbname=exampledb" $ do
  result <- runQueryParams roundTrip input
  Just output <- firstRow result
  liftBase . print $ input == output
:}
True

In addition to being able to encode and decode basic Haskell types
like `Int16` and `Data.Text.Text`, Squeal permits you to encode and decode Haskell types to
Postgres array, enumerated and composite types and json. Let's see another example,
this time using the `Vector` type which corresponds to variable length arrays
and homogeneous tuples which correspond to fixed length arrays. We can even
create multi-dimensional fixed length arrays.

>>> :{
data Row = Row
  { col1 :: VarArray (Vector Int16)
  , col2 :: FixArray (Maybe Int16,Maybe Int16)
  , col3 :: FixArray ((Int16,Int16),(Int16,Int16),(Int16,Int16))
  } deriving (Eq, GHC.Generic)
:}

>>> instance Generic Row
>>> instance HasDatatypeInfo Row

Once again, we define a simple round trip query.

>>> :{
let
  roundTrip :: Query_ (Public '[]) Row Row
  roundTrip = values_ $
    parameter @1 (int2 & vararray) `as` #col1 :*
    parameter @2 (int2 & fixarray @'[2]) `as` #col2 :*
    parameter @3 (int2 & fixarray @'[3,2]) `as` #col3
:}

>>> :set -XOverloadedLists
>>> let input = Row (VarArray [1,2]) (FixArray (Just 1,Nothing)) (FixArray ((1,2),(3,4),(5,6)))
>>> :{
void . withConnection "host=localhost port=5432 dbname=exampledb" $ do
  result <- runQueryParams roundTrip input
  Just output <- firstRow result
  liftBase . print $ input == output
:}
True

Enumerated (enum) types are data types that comprise a static, ordered set of values.
They are equivalent to Haskell algebraic data types whose constructors are nullary.
An example of an enum type might be the days of the week,
or a set of status values for a piece of data.

>>> data Schwarma = Beef | Lamb | Chicken deriving (Eq, Show, GHC.Generic)
>>> instance Generic Schwarma
>>> instance HasDatatypeInfo Schwarma

A composite type represents the structure of a row or record;
it is essentially just a list of field names and their data types.

>>> data Person = Person {name :: Text, age :: Int32} deriving (Eq, Show, GHC.Generic)
>>> instance Generic Person
>>> instance HasDatatypeInfo Person
>>> instance Aeson.FromJSON Person
>>> instance Aeson.ToJSON Person

We can create the equivalent Postgres types directly from their Haskell types.

>>> :{
type Schema =
  '[ "schwarma" ::: 'Typedef (PG (Enumerated Schwarma))
   , "person" ::: 'Typedef (PG (Composite Person))
   ]
:}

>>> :{
let
  setup :: Definition (Public '[]) (Public Schema)
  setup =
    createTypeEnumFrom @Schwarma #schwarma >>>
    createTypeCompositeFrom @Person #person
:}

Let's demonstrate how to associate our Haskell types @Schwarma@ and @Person@
with enumerated, composite or json types in Postgres. First create a Haskell
@Row@ type using the `Enumerated`, `Composite` and `Json` newtypes as fields.

>>> :{
data Row = Row
  { schwarma :: Enumerated Schwarma
  , person1 :: Composite Person
  , person2 :: Json Person
  } deriving (Eq, GHC.Generic)
:}

>>> instance Generic Row
>>> instance HasDatatypeInfo Row
>>> :{
let
  input = Row
    (Enumerated Chicken)
    (Composite (Person "Faisal" 24))
    (Json (Person "Ahmad" 48))
:}

Once again, define a round trip query.

>>> :{
let
  roundTrip :: Query_ (Public Schema) Row Row
  roundTrip = values_ $
    parameter @1 (typedef #schwarma) `as` #schwarma :*
    parameter @2 (typedef #person)   `as` #person1  :*
    parameter @3 json                `as` #person2
:}

Finally, we can drop our type definitions.

>>> :{
let
  teardown :: Definition (Public Schema) (Public '[])
  teardown = dropType #schwarma >>> dropType #person
:}

Now let's run it.

>>> :{
let
  session = do
    result <- runQueryParams roundTrip input
    Just output <- firstRow result
    liftBase . print $ input == output
in
  void . withConnection "host=localhost port=5432 dbname=exampledb" $
    define setup
    & pqThen session
    & pqThen (define teardown)
:}
True
-}

{-# LANGUAGE
    AllowAmbiguousTypes
  , DeriveFoldable
  , DeriveFunctor
  , DeriveGeneric
  , DeriveTraversable
  , DefaultSignatures
  , FlexibleContexts
  , FlexibleInstances
  , FunctionalDependencies
  , GADTs
  , LambdaCase
  , OverloadedStrings
  , MultiParamTypeClasses
  , ScopedTypeVariables
  , TypeApplications
  , TypeFamilies
  , TypeInType
  , TypeOperators
  , UndecidableInstances
  , UndecidableSuperClasses
#-}

module Squeal.PostgreSQL.Binary
  ( -- * PG type families
    PG
  , NullPG
  , TuplePG
  , RowPG
  , LabelsPG
    -- * Storage newtypes
  , Money (..)
  , Json (..)
  , Jsonb (..)
  , Composite (..)
  , Enumerated (..)
  , VarArray (..)
  , FixArray (..)
    -- * Encoding
  , ToParam (..)
  , ToParams (..)
    -- * Decoding
  , FromValue (..)
  , FromRow (..)
    -- * Only
  , Only (..)
  , P (..)
  ) where

import BinaryParser
import ByteString.StrictBuilder (builderLength, int32BE, int64BE, word32BE)
import Control.Arrow (left)
import Control.Monad
import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.Int
import Data.Kind
import Data.Scientific
import Data.Text (Text)
import Data.Time
import Data.UUID.Types
import Data.Vector (Vector)
import Data.Word
import Generics.SOP
import Generics.SOP.Record
import GHC.TypeLits
import Network.IP.Addr

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as Lazy (ByteString)
import qualified Data.ByteString.Lazy as Lazy.ByteString
import qualified Data.ByteString as Strict (ByteString)
import qualified Data.Text.Lazy as Lazy (Text)
import qualified Data.Text as Strict (Text)
import qualified Data.Text as Strict.Text
import qualified Data.Vector as Vector
import qualified Generics.SOP.Type.Metadata as Type
import qualified GHC.Generics as GHC
import qualified PostgreSQL.Binary.Decoding as Decoding
import qualified PostgreSQL.Binary.Encoding as Encoding

import Squeal.PostgreSQL.Schema

-- | A `ToParam` constraint gives an encoding of a Haskell `Type` into
-- into the binary format of a PostgreSQL `PGType`.
class ToParam (x :: Type) (pg :: PGType) where
  -- | >>> :set -XTypeApplications -XDataKinds
  -- >>> toParam @Bool @'PGbool False
  -- K "\NUL"
  --
  -- >>> toParam @Int16 @'PGint2 0
  -- K "\NUL\NUL"
  --
  -- >>> toParam @Int32 @'PGint4 0
  -- K "\NUL\NUL\NUL\NUL"
  --
  -- >>> :set -XMultiParamTypeClasses
  -- >>> newtype Id = Id { getId :: Int16 } deriving Show
  -- >>> instance ToParam Id 'PGint2 where toParam = toParam . getId
  -- >>> toParam @Id @'PGint2 (Id 1)
  -- K "\NUL\SOH"
  toParam :: x -> K Encoding.Encoding pg
instance ToParam Bool 'PGbool where toParam = K . Encoding.bool
instance ToParam Int16 'PGint2 where toParam = K . Encoding.int2_int16
instance ToParam Word16 'PGint2 where toParam = K . Encoding.int2_word16
instance ToParam Int32 'PGint4 where toParam = K . Encoding.int4_int32
instance ToParam Word32 'PGint4 where toParam = K . Encoding.int4_word32
instance ToParam Int64 'PGint8 where toParam = K . Encoding.int8_int64
instance ToParam Word64 'PGint8 where toParam = K . Encoding.int8_word64
instance ToParam Float 'PGfloat4 where toParam = K . Encoding.float4
instance ToParam Double 'PGfloat8 where toParam = K . Encoding.float8
instance ToParam Scientific 'PGnumeric where toParam = K . Encoding.numeric
instance ToParam Money 'PGmoney where toParam = K . Encoding.int8_int64 . cents
instance ToParam UUID 'PGuuid where toParam = K . Encoding.uuid
instance ToParam (NetAddr IP) 'PGinet where toParam = K . Encoding.inet
instance ToParam Char ('PGchar 1) where toParam = K . Encoding.char_utf8
instance ToParam Strict.Text 'PGtext where toParam = K . Encoding.text_strict
instance ToParam Lazy.Text 'PGtext where toParam = K . Encoding.text_lazy
instance ToParam String 'PGtext where
  toParam = K . Encoding.text_strict . Strict.Text.pack
instance ToParam Strict.ByteString 'PGbytea where
  toParam = K . Encoding.bytea_strict
instance ToParam Lazy.ByteString 'PGbytea where
  toParam = K . Encoding.bytea_lazy
instance ToParam Day 'PGdate where toParam = K . Encoding.date
instance ToParam TimeOfDay 'PGtime where toParam = K . Encoding.time_int
instance ToParam (TimeOfDay, TimeZone) 'PGtimetz where
  toParam = K . Encoding.timetz_int
instance ToParam LocalTime 'PGtimestamp where
  toParam = K . Encoding.timestamp_int
instance ToParam UTCTime 'PGtimestamptz where
  toParam = K . Encoding.timestamptz_int
instance ToParam DiffTime 'PGinterval where toParam = K . Encoding.interval_int
instance ToParam Aeson.Value 'PGjson where toParam = K . Encoding.json_ast
instance ToParam Aeson.Value 'PGjsonb where toParam = K . Encoding.jsonb_ast
instance Aeson.ToJSON x => ToParam (Json x) 'PGjson where
  toParam = K . Encoding.json_bytes
    . Lazy.ByteString.toStrict . Aeson.encode . getJson
instance Aeson.ToJSON x => ToParam (Jsonb x) 'PGjsonb where
  toParam = K . Encoding.jsonb_bytes
    . Lazy.ByteString.toStrict . Aeson.encode . getJsonb
instance (ToNullityParam x ty, ty ~ nullity pg, HasOid pg)
  => ToParam (VarArray [x]) ('PGvararray ty) where
    toParam = K
      . Encoding.array_foldable (oid @pg) (unK . toNullityParam @x @ty)
      . getVarArray
instance (ToParam x pg, HasOid pg)
  => ToParam (VarArray (Vector x)) ('PGvararray ('NotNull pg)) where
    toParam = K
      . Encoding.array_vector (oid @pg) (unK . toParam @x @pg)
      . getVarArray
instance (ToParam x pg, HasOid pg)
  => ToParam (VarArray (Vector (Maybe x))) ('PGvararray ('Null pg)) where
    toParam = K
      . Encoding.nullableArray_vector (oid @pg) (unK . toParam @x @pg)
      . getVarArray
instance (ToFixArray x dims ty, ty ~ nullity pg, HasOid pg)
  => ToParam (FixArray x) ('PGfixarray dims ty) where
    toParam = K . Encoding.array (oid @pg)
      . unK . unK . toFixArray @x @dims @ty . getFixArray
instance
  ( IsEnumType x
  , HasDatatypeInfo x
  , LabelsPG x ~ labels
  ) => ToParam (Enumerated x) ('PGenum labels) where
    toParam =
      let
        gshowConstructor :: NP ConstructorInfo xss -> SOP I xss -> String
        gshowConstructor Nil _ = ""
        gshowConstructor (constructor :* _) (SOP (Z _)) =
          constructorName constructor
        gshowConstructor (_ :* constructors) (SOP (S xs)) =
          gshowConstructor constructors (SOP xs)
      in
        K . Encoding.text_strict
        . Strict.Text.pack
        . gshowConstructor (constructorInfo (datatypeInfo (Proxy @x)))
        . from
        . getEnumerated
instance
  ( SListI fields
  , IsRecord x xs
  , AllZip ToField xs fields
  , All HasAliasedOid fields
  ) => ToParam (Composite x) ('PGcomposite fields) where
    toParam =
      let

        encoders = htrans (Proxy @ToField) toField

        composite
          :: All HasAliasedOid row
          => NP (K (Maybe Encoding.Encoding)) row
          -> K Encoding.Encoding ('PGcomposite row)
        composite fields = K $
          -- <number of fields: 4 bytes>
          -- [for each field]
          --  <OID of field's type: sizeof(Oid) bytes>
          --  [if value is NULL]
          --    <-1: 4 bytes>
          --  [else]
          --    <length of value: 4 bytes>
          --    <value: <length> bytes>
          --  [end if]
          -- [end for]
          int32BE (fromIntegral (lengthSList (Proxy @xs))) <>
            let
              each
                :: HasAliasedOid field
                => K (Maybe Encoding.Encoding) field
                -> Encoding.Encoding
              each (K field :: K (Maybe Encoding.Encoding) field) =
                word32BE (aliasedOid @field)
                <> case field of
                  Nothing -> int64BE (-1)
                  Just value ->
                    int32BE (fromIntegral (builderLength value))
                    <> value
            in
              hcfoldMap (Proxy @HasAliasedOid) each fields

      in
        composite . encoders . toRecord . getComposite

class HasAliasedOid (field :: (Symbol, NullityType)) where
  aliasedOid :: Word32
instance HasOid ty => HasAliasedOid (alias ::: nullity ty) where
  aliasedOid = oid @ty

class ToNullityParam (x :: Type) (ty :: NullityType) where
  toNullityParam :: x -> K (Maybe Encoding.Encoding) ty
instance ToParam x pg => ToNullityParam x ('NotNull pg) where
  toNullityParam = K . Just . unK . toParam @x @pg
instance ToParam x pg => ToNullityParam (Maybe x) ('Null pg) where
  toNullityParam = K . fmap (unK . toParam @x @pg)

class ToField (x :: (Symbol, Type)) (field :: (Symbol, NullityType)) where
  toField :: P x -> K (Maybe Encoding.Encoding) field
instance ToNullityParam x ty => ToField (alias ::: x) (alias ::: ty) where
  toField (P x) = K . unK $ toNullityParam @x @ty x

class ToFixArray (x :: Type) (dims :: [Nat]) (array :: NullityType) where
  toFixArray :: x -> K (K Encoding.Array dims) array
instance ToNullityParam x ty => ToFixArray x '[] ty where
  toFixArray = K . K . maybe Encoding.nullArray Encoding.encodingArray . unK
    . toNullityParam @x @ty
instance
  ( IsProductType product xs
  , Length xs ~ dim
  , All ((~) x) xs
  , ToFixArray x dims ty )
  => ToFixArray product (dim ': dims) ty where
    toFixArray = K . K . Encoding.dimensionArray foldlN
      (unK . unK . toFixArray @x @dims @ty) . unZ . unSOP . from

-- | A `ToParams` constraint generically sequences the encodings of `Type`s
-- of the fields of a tuple or record to a row of `ColumnType`s. You should
-- not define instances of `ToParams`. Instead define `SOP.Generic` instances
-- which in turn provide `ToParams` instances.
class SListI tys => ToParams (x :: Type) (tys :: [NullityType]) where
  -- | >>> type Params = '[ 'NotNull 'PGbool, 'Null 'PGint2]
  -- >>> toParams @(Bool, Maybe Int16) @'[ 'NotNull 'PGbool, 'Null 'PGint2] (False, Just 0)
  -- K (Just "\NUL") :* K (Just "\NUL\NUL") :* Nil
  --
  -- >>> :set -XDeriveGeneric
  -- >>> data Tuple = Tuple { p1 :: Bool, p2 :: Maybe Int16} deriving GHC.Generic
  -- >>> instance Generic Tuple
  -- >>> toParams @Tuple @Params (Tuple False (Just 0))
  -- K (Just "\NUL") :* K (Just "\NUL\NUL") :* Nil
  toParams :: x -> NP (K (Maybe Encoding.Encoding)) tys
instance (SListI tys, IsProductType x xs, AllZip ToNullityParam xs tys)
  => ToParams x tys where
      toParams
        = htrans (Proxy @ToNullityParam) (toNullityParam . unI)
        . unZ . unSOP . from

-- | A `FromValue` constraint gives a parser from the binary format of
-- a PostgreSQL `PGType` into a Haskell `Type`.
class FromValue (pg :: PGType) (y :: Type) where
  -- | >>> newtype Id = Id { getId :: Int16 } deriving Show
  -- >>> instance FromValue 'PGint2 Id where fromValue = Id <$> fromValue @'PGint2
  fromValue :: Decoding.Value y
instance FromValue 'PGbool Bool where fromValue = Decoding.bool
instance FromValue 'PGint2 Int16 where fromValue = Decoding.int
instance FromValue 'PGint4 Int32 where fromValue = Decoding.int
instance FromValue 'PGint8 Int64 where fromValue = Decoding.int
instance FromValue 'PGfloat4 Float where fromValue = Decoding.float4
instance FromValue 'PGfloat8 Double where fromValue = Decoding.float8
instance FromValue 'PGnumeric Scientific where fromValue = Decoding.numeric
instance FromValue 'PGmoney Money where fromValue = Money <$> Decoding.int
instance FromValue 'PGuuid UUID where fromValue = Decoding.uuid
instance FromValue 'PGinet (NetAddr IP) where fromValue = Decoding.inet
instance FromValue ('PGchar 1) Char where fromValue = Decoding.char
instance FromValue 'PGtext Strict.Text where fromValue = Decoding.text_strict
instance FromValue 'PGtext Lazy.Text where fromValue = Decoding.text_lazy
instance FromValue 'PGtext String where
  fromValue = Strict.Text.unpack <$> Decoding.text_strict
instance FromValue 'PGbytea Strict.ByteString where
  fromValue = Decoding.bytea_strict
instance FromValue 'PGbytea Lazy.ByteString where
  fromValue = Decoding.bytea_lazy
instance FromValue 'PGdate Day where fromValue = Decoding.date
instance FromValue 'PGtime TimeOfDay where fromValue = Decoding.time_int
instance FromValue 'PGtimetz (TimeOfDay, TimeZone) where
  fromValue = Decoding.timetz_int
instance FromValue 'PGtimestamp LocalTime where
  fromValue = Decoding.timestamp_int
instance FromValue 'PGtimestamptz UTCTime where
  fromValue = Decoding.timestamptz_int
instance FromValue 'PGinterval DiffTime where
  fromValue = Decoding.interval_int
instance FromValue 'PGjson Aeson.Value where fromValue = Decoding.json_ast
instance FromValue 'PGjsonb Aeson.Value where fromValue = Decoding.jsonb_ast
instance Aeson.FromJSON x => FromValue 'PGjson (Json x) where
  fromValue = Json <$>
    Decoding.json_bytes (left Strict.Text.pack . Aeson.eitherDecodeStrict)
instance Aeson.FromJSON x => FromValue 'PGjsonb (Jsonb x) where
  fromValue = Jsonb <$>
    Decoding.jsonb_bytes (left Strict.Text.pack . Aeson.eitherDecodeStrict)
instance FromValue pg y
  => FromValue ('PGvararray ('NotNull pg)) (VarArray (Vector y)) where
    fromValue =
      let
        rep n x = VarArray <$> Vector.replicateM n x
      in
        Decoding.array $ Decoding.dimensionArray rep
          (fromFixArray @'[] @('NotNull pg))
instance FromValue pg y
  => FromValue ('PGvararray ('Null pg)) (VarArray (Vector (Maybe y))) where
    fromValue =
      let
        rep n x = VarArray <$> Vector.replicateM n x
      in
        Decoding.array $ Decoding.dimensionArray rep
          (fromFixArray @'[] @('Null pg))
instance FromValue pg y
  => FromValue ('PGvararray ('NotNull pg)) (VarArray [y]) where
    fromValue =
      let
        rep n x = VarArray <$> replicateM n x
      in
        Decoding.array $ Decoding.dimensionArray rep
          (fromFixArray @'[] @('NotNull pg))
instance FromValue pg y
  => FromValue ('PGvararray ('Null pg)) (VarArray [Maybe y]) where
    fromValue =
      let
        rep n x = VarArray <$> replicateM n x
      in
        Decoding.array $ Decoding.dimensionArray rep
          (fromFixArray @'[] @('Null pg))
instance FromFixArray dims ty y
  => FromValue ('PGfixarray dims ty) (FixArray y) where
    fromValue = FixArray <$> Decoding.array (fromFixArray @dims @ty @y)
instance
  ( IsEnumType y
  , HasDatatypeInfo y
  , LabelsPG y ~ labels
  ) => FromValue ('PGenum labels) (Enumerated y) where
    fromValue =
      let
        greadConstructor
          :: All ((~) '[]) xss
          => NP ConstructorInfo xss
          -> String
          -> Maybe (SOP I xss)
        greadConstructor Nil _ = Nothing
        greadConstructor (constructor :* constructors) name =
          if name == constructorName constructor
            then Just (SOP (Z Nil))
            else SOP . S . unSOP <$> greadConstructor constructors name
      in
        fmap Enumerated
        . Decoding.enum
        $ fmap to
        . greadConstructor (constructorInfo (datatypeInfo (Proxy @y)))
        . Strict.Text.unpack
instance
  ( FromRow fields y
  ) => FromValue ('PGcomposite fields) (Composite y) where
    fromValue =
      let
        -- <number of fields: 4 bytes>
        -- [for each field]
        --  <OID of field's type: sizeof(Oid) bytes>
        --  [if value is NULL]
        --    <-1: 4 bytes>
        --  [else]
        --    <length of value: 4 bytes>
        --    <value: <length> bytes>
        --  [end if]
        -- [end for]
        composite = Decoding.valueParser $ do
          unitOfSize 4
          hsequence' $ hpure $ Comp $ do
            unitOfSize 4
            len <- sized 4 Decoding.int
            if len == -1
              then return (K Nothing)
              else K . Just <$> bytesOfSize len
      in
        fmap Composite (Decoding.fn (fromRow @fields <=< composite))

-- | A `FromField` constraint lifts the `FromValue` parser
-- to a decoding of a @(Symbol, NullityType)@ to a `Type`,
-- decoding `Null`s to `Maybe`s. You should not define instances for
-- `FromField`, just use the provided instances.
class FromField (pg :: (Symbol, NullityType)) (y :: (Symbol, Type)) where
  fromField
    :: K (Maybe Strict.ByteString) pg
    -> (Either Strict.Text :.: P) y
instance FromValue pg y
  => FromField (column ::: ('NotNull pg)) (column ::: y) where
    fromField = Comp . \case
      K Nothing -> Left "fromField: saw NULL when expecting NOT NULL"
      K (Just bytestring) -> P <$>
        Decoding.valueParser (fromValue @pg) bytestring
instance FromValue pg y
  => FromField (column ::: 'Null pg) (column ::: Maybe y) where
    fromField = Comp . \case
      K Nothing -> Right $ P Nothing
      K (Just bytestring) -> P . Just <$>
        Decoding.valueParser (fromValue @pg) bytestring

class FromFixArray (dims :: [Nat]) (ty :: NullityType) (y :: Type) where
  fromFixArray :: Decoding.Array y
instance FromValue pg y => FromFixArray '[] ('NotNull pg) y where
  fromFixArray = Decoding.valueArray (fromValue @pg @y)
instance FromValue pg y => FromFixArray '[] ('Null pg) (Maybe y) where
  fromFixArray = Decoding.nullableValueArray (fromValue @pg @y)
instance
  ( IsProductType product ys
  , Length ys ~ dim
  , All ((~) y) ys
  , FromFixArray dims ty y )
  => FromFixArray (dim ': dims) ty product where
    fromFixArray =
      let
        rep _ = fmap (to . SOP . Z) . replicateMN
      in
        Decoding.dimensionArray rep (fromFixArray @dims @ty @y)

-- | A `FromRow` constraint generically sequences the parsings of the columns
-- of a `RowType` into the fields of a record `Type` provided they have
-- the same field names. You should not define instances of `FromRow`.
-- Instead define `SOP.Generic` and `SOP.HasDatatypeInfo` instances which in turn
-- provide `FromRow` instances.
class SListI result => FromRow (result :: RowType) y where
  -- | >>> :set -XOverloadedStrings
  -- >>> import Data.Text
  -- >>> newtype UserId = UserId { getUserId :: Int16 } deriving Show
  -- >>> instance FromValue 'PGint2 UserId where fromValue = UserId <$> fromValue @'PGint2
  -- >>> data UserRow = UserRow { userId :: UserId, userName :: Maybe Text } deriving (Show, GHC.Generic)
  -- >>> instance Generic UserRow
  -- >>> instance HasDatatypeInfo UserRow
  -- >>> type User = '["userId" ::: 'NotNull 'PGint2, "userName" ::: 'Null 'PGtext]
  -- >>> fromRow @User @UserRow (K (Just "\NUL\SOH") :* K (Just "bloodninja") :* Nil)
  -- Right (UserRow {userId = UserId {getUserId = 1}, userName = Just "bloodninja"})
  fromRow :: NP (K (Maybe Strict.ByteString)) result -> Either Strict.Text y
instance
  ( SListI result
  , IsRecord y ys
  , AllZip FromField result ys
  ) => FromRow result y where
    fromRow
      = fmap fromRecord
      . hsequence'
      . htrans (Proxy @FromField) fromField
instance (FromField (col ::: pg) (col ::: hask))
  => FromRow '[col ::: pg] (P (col ::: hask)) where
    fromRow (pg :* Nil) = (unComp . fromField) pg
instance
  ( row ~ Join row1 row2
  , FromRow row1 hask1
  , FromRow row2 hask2
  , SListI row
  ) => FromRow row (hask1, hask2) where
    fromRow row = case disjoin @row1 @row2 row of
      (row1, row2) -> (,) <$> fromRow row1 <*> fromRow row2
instance
  ( row ~ Join row1 row23
  , FromRow row1 hask1
  , FromRow row23 (hask2, hask3)
  , SListI row
  ) => FromRow row (hask1, hask2, hask3) where
    fromRow row = case disjoin @row1 @row23 row of
      (row1, row23) -> do
        hask1 <- fromRow row1
        (hask2, hask3) <- fromRow row23
        return (hask1, hask2, hask3)
instance
  ( row ~ Join row1 row234
  , FromRow row1 hask1
  , FromRow row234 (hask2, hask3, hask4)
  , SListI row
  ) => FromRow row (hask1, hask2, hask3, hask4) where
    fromRow row = case disjoin @row1 @row234 row of
      (row1, row234) -> do
        hask1 <- fromRow row1
        (hask2, hask3, hask4) <- fromRow row234
        return (hask1, hask2, hask3, hask4)
instance
  ( row ~ Join row1 row2345
  , FromRow row1 hask1
  , FromRow row2345 (hask2, hask3, hask4, hask5)
  , SListI row
  ) => FromRow row (hask1, hask2, hask3, hask4, hask5) where
    fromRow row = case disjoin @row1 @row2345 row of
      (row1, row2345) -> do
        hask1 <- fromRow row1
        (hask2, hask3, hask4, hask5) <- fromRow row2345
        return (hask1, hask2, hask3, hask4, hask5)

-- | `Only` is a 1-tuple type, useful for encoding a single parameter with
-- `toParams` or decoding a single value with `fromRow`.
--
-- >>> import Data.Text
-- >>> toParams @(Only (Maybe Text)) @'[ 'Null 'PGtext] (Only (Just "foo"))
-- K (Just "foo") :* Nil
--
-- >>> fromRow @'["fromOnly" ::: 'Null 'PGtext] @(Only (Maybe Text)) (K (Just "bar") :* Nil)
-- Right (Only {fromOnly = Just "bar"})
newtype Only x = Only { fromOnly :: x }
  deriving (Functor,Foldable,Traversable,Eq,Ord,Read,Show,GHC.Generic)
instance Generic (Only x)
instance HasDatatypeInfo (Only x)

foldlN
  :: All ((~) x) xs
  => (z -> x -> z) -> z -> NP I xs -> z
foldlN f z = \case
  Nil -> z
  I x :* xs -> let z' = f z x in seq z' $ foldlN f z' xs

replicateMN
  :: forall x xs m. (All ((~) x) xs, Monad m, SListI xs)
  => m x -> m (NP I xs)
replicateMN mx = hsequence' $
  hcpure (Proxy :: Proxy ((~) x)) (Comp (I <$> mx))

{- | The `Money` newtype stores a monetary value in terms
of the number of cents, i.e. @$2,000.20@ would be expressed as
@Money { cents = 200020 }@.

>>> import Control.Monad (void)
>>> import Control.Monad.Base (liftBase)
>>> import Squeal.PostgreSQL
>>> :{
let
  roundTrip :: Query_ (Public '[]) (Only Money) (Only Money)
  roundTrip = values_ $ parameter @1 money `as` #fromOnly
:}

>>> let input = Only (Money 20020)

>>> :{
void . withConnection "host=localhost port=5432 dbname=exampledb" $ do
  result <- runQueryParams roundTrip input
  Just output <- firstRow result
  liftBase . print $ input == output
:}
True
-}
newtype Money = Money { cents :: Int64 }
  deriving (Eq, Ord, Show, Read, GHC.Generic)
type instance PG Money = 'PGmoney

{- | The `Json` newtype is an indication that the Haskell
type it's applied to should be stored as a `PGjson`.
-}
newtype Json hask = Json {getJson :: hask}
  deriving (Eq, Ord, Show, Read, GHC.Generic)
type instance PG (Json hask) = 'PGjson

{- | The `Jsonb` newtype is an indication that the Haskell
type it's applied to should be stored as a `PGjsonb`.
-}
newtype Jsonb hask = Jsonb {getJsonb :: hask}
  deriving (Eq, Ord, Show, Read, GHC.Generic)
type instance PG (Jsonb hask) = 'PGjsonb

{- | The `Composite` newtype is an indication that the Haskell
type it's applied to should be stored as a `PGcomposite`.
-}
newtype Composite record = Composite {getComposite :: record}
  deriving (Eq, Ord, Show, Read, GHC.Generic)
type instance PG (Composite hask) = 'PGcomposite (RowPG hask)

{- | The `Enumerated` newtype is an indication that the Haskell
type it's applied to should be stored as a `PGenum`.
-}
newtype Enumerated enum = Enumerated {getEnumerated :: enum}
  deriving (Eq, Ord, Show, Read, GHC.Generic)
type instance PG (Enumerated hask) = 'PGenum (LabelsPG hask)

{- | The `VarArray` newtype is an indication that the Haskell
type it's applied to should be stored as a `PGvararray`.
-}
newtype VarArray arr = VarArray {getVarArray :: arr}
  deriving (Eq, Ord, Show, Read, GHC.Generic)
type instance PG (VarArray (Vector hask)) = 'PGvararray (NullPG hask)

{- | The `FixArray` newtype is an indication that the Haskell
type it's applied to should be stored as a `PGfixarray`.
-}
newtype FixArray arr = FixArray {getFixArray :: arr}
  deriving (Eq, Ord, Show, Read, GHC.Generic)
type instance PG (FixArray x) = 'PGfixarray (DimPG x) (FixPG x)

type family DimPG (hask :: Type) :: [Nat] where
  DimPG (x,x) = 2 ': DimPG x
  DimPG (x,x,x) = 3 ': DimPG x
  DimPG (x,x,x,x) = 4 ': DimPG x
  DimPG (x,x,x,x,x) = 5 ': DimPG x
  DimPG (x,x,x,x,x,x) = 6 ': DimPG x
  DimPG (x,x,x,x,x,x,x) = 7 ': DimPG x
  DimPG (x,x,x,x,x,x,x,x) = 8 ': DimPG x
  DimPG (x,x,x,x,x,x,x,x,x) = 9 ': DimPG x
  DimPG (x,x,x,x,x,x,x,x,x,x) = 10 ': DimPG x
  DimPG x = '[]

type family FixPG (hask :: Type) :: NullityType where
  FixPG (x,x) = FixPG x
  FixPG (x,x,x) = FixPG x
  FixPG (x,x,x,x) = FixPG x
  FixPG (x,x,x,x,x) = FixPG x
  FixPG (x,x,x,x,x,x) = FixPG x
  FixPG (x,x,x,x,x,x,x) = FixPG x
  FixPG (x,x,x,x,x,x,x,x) = FixPG x
  FixPG (x,x,x,x,x,x,x,x,x) = FixPG x
  FixPG (x,x,x,x,x,x,x,x,x,x) = FixPG x
  FixPG (x,x,x,x,x,x,x,x,x,x,x) = FixPG x
  FixPG x = NullPG x

{- | The `PG` type family embeds a subset of Haskell types
as Postgres types. As an open type family, `PG` is extensible.

>>> :kind! PG LocalTime
PG LocalTime :: PGType
= 'PGtimestamp

>>> newtype MyDouble = My Double
>>> :set -XTypeFamilies
>>> type instance PG MyDouble = 'PGfloat8
-}
type family PG (hask :: Type) :: PGType
type instance PG Bool = 'PGbool
type instance PG Int16 = 'PGint2
type instance PG Int32 = 'PGint4
type instance PG Int64 = 'PGint8
type instance PG Word16 = 'PGint2
type instance PG Word32 = 'PGint4
type instance PG Word64 = 'PGint8
type instance PG Scientific = 'PGnumeric
type instance PG Float = 'PGfloat4
type instance PG Double = 'PGfloat8
type instance PG Char = 'PGchar 1
type instance PG Text = 'PGtext
type instance PG Lazy.Text = 'PGtext
type instance PG String = 'PGtext
type instance PG ByteString = 'PGbytea
type instance PG Lazy.ByteString = 'PGbytea
type instance PG LocalTime = 'PGtimestamp
type instance PG UTCTime = 'PGtimestamptz
type instance PG Day = 'PGdate
type instance PG TimeOfDay = 'PGtime
type instance PG (TimeOfDay, TimeZone) = 'PGtimetz
type instance PG DiffTime = 'PGinterval
type instance PG UUID = 'PGuuid
type instance PG (NetAddr IP) = 'PGinet
type instance PG Value = 'PGjson

{-| The `LabelsPG` type family calculates the constructors of a
Haskell enum type.

>>> data Schwarma = Beef | Lamb | Chicken deriving GHC.Generic
>>> instance Generic Schwarma
>>> instance HasDatatypeInfo Schwarma
>>> :kind! LabelsPG Schwarma
LabelsPG Schwarma :: [Type.ConstructorName]
= '["Beef", "Lamb", "Chicken"]
-}
type family LabelsPG (hask :: Type) :: [Type.ConstructorName] where
  LabelsPG hask =
    ConstructorNamesOf (ConstructorsOf (DatatypeInfoOf hask))

{- | `RowPG` turns a Haskell record type into a `RowType`.

>>> data Person = Person { name :: Text, age :: Int32 } deriving GHC.Generic
>>> instance Generic Person
>>> instance HasDatatypeInfo Person
>>> :kind! RowPG Person
RowPG Person :: [(Symbol, NullityType)]
= '["name" ::: 'NotNull 'PGtext, "age" ::: 'NotNull 'PGint4]
-}
type family RowPG (hask :: Type) :: RowType where
  RowPG (hask1, hask2) = Join (RowPG hask1) (RowPG hask2)
  RowPG (hask1, hask2, hask3) =
    Join (RowPG hask1) (RowPG (hask2, hask3))
  RowPG (hask1, hask2, hask3, hask4) =
    Join (RowPG hask1) (RowPG (hask2, hask3, hask4))
  RowPG (hask1, hask2, hask3, hask4, hask5) =
    Join (RowPG hask1) (RowPG (hask2, hask3, hask4, hask5))
  RowPG (P (col ::: head)) = '[col ::: NullPG head]
  RowPG hask = RowOf (RecordCodeOf hask)

type family RowOf (fields :: [(Symbol, Type)]) :: RowType where
  RowOf '[] = '[]
  RowOf (field ': fields) = FieldPG field ': RowOf fields

type family FieldPG (field :: (Symbol, Type)) :: (Symbol, NullityType) where
  FieldPG (field ::: hask) = field ::: NullPG hask

{- | `NullPG` turns a Haskell type into a `NullityType`.

>>> :kind! NullPG Double
NullPG Double :: NullityType
= 'NotNull 'PGfloat8
>>> :kind! NullPG (Maybe Double)
NullPG (Maybe Double) :: NullityType
= 'Null 'PGfloat8
-}
type family NullPG (hask :: Type) :: NullityType where
  NullPG (Maybe hask) = 'Null (PG hask)
  NullPG hask = 'NotNull (PG hask)

{- | `TuplePG` turns a Haskell tuple type (including record types) into
the corresponding list of `NullityType`s.

>>> :kind! TuplePG (Double, Maybe Char)
TuplePG (Double, Maybe Char) :: [NullityType]
= '[ 'NotNull 'PGfloat8, 'Null ('PGchar 1)]
-}
type family TuplePG (hask :: Type) :: [NullityType] where
  TuplePG hask = TupleOf (TupleCodeOf hask (Code hask))

type family TupleOf (tuple :: [Type]) :: [NullityType] where
  TupleOf '[] = '[]
  TupleOf (hask ': tuple) = NullPG hask ': TupleOf tuple

type family TupleCodeOf (hask :: Type) (code :: [[Type]]) :: [Type] where
  TupleCodeOf hask '[tuple] = tuple
  TupleCodeOf hask '[] =
    TypeError
      (    'Text "The type `" ':<>: 'ShowType hask ':<>: 'Text "' is not a tuple type."
      ':$$: 'Text "It is a void type with no constructors."
      )
  TupleCodeOf hask (_ ': _ ': _) =
    TypeError
      (    'Text "The type `" ':<>: 'ShowType hask ':<>: 'Text "' is not a tuple type."
      ':$$: 'Text "It is a sum type with more than one constructor."
      )

-- | Calculates constructors of a datatype.
type family ConstructorsOf (datatype :: Type.DatatypeInfo)
  :: [Type.ConstructorInfo] where
    ConstructorsOf ('Type.ADT _module _datatype constructors) =
      constructors
    ConstructorsOf ('Type.Newtype _module _datatype constructor) =
      '[constructor]

-- | Calculates the name of a nullary constructor, otherwise
-- generates a type error.
type family ConstructorNameOf (constructors :: Type.ConstructorInfo)
  :: Type.ConstructorName where
    ConstructorNameOf ('Type.Constructor name) = name
    ConstructorNameOf ('Type.Infix name _assoc _fix) = TypeError
      ('Text "ConstructorNameOf error: non-nullary constructor "
        ':<>: 'Text name)
    ConstructorNameOf ('Type.Record name _fields) = TypeError
      ('Text "ConstructorNameOf error: non-nullary constructor "
        ':<>: 'Text name)

-- | Calculate the names of nullary constructors.
type family ConstructorNamesOf (constructors :: [Type.ConstructorInfo])
  :: [Type.ConstructorName] where
    ConstructorNamesOf '[] = '[]
    ConstructorNamesOf (constructor ': constructors) =
      ConstructorNameOf constructor ': ConstructorNamesOf constructors
