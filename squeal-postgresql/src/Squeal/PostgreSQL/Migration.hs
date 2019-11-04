{-|
Module: Squeal.PostgreSQL.Migration
Description: Squeal migrations
Copyright: (c) Eitan Chatav, 2017
Maintainer: eitan@morphism.tech
Stability: experimental

This module defines a `Migration` type to safely
change the schema of your database over time. Let's see an example!

First turn on some extensions.

>>> :set -XDataKinds -XOverloadedLabels
>>> :set -XOverloadedStrings -XFlexibleContexts -XTypeOperators

Next, let's define our `TableType`s.

>>> :{
type UsersTable =
  '[ "pk_users" ::: 'PrimaryKey '["id"] ] :=>
  '[ "id" ::: 'Def :=> 'NotNull 'PGint4
   , "name" ::: 'NoDef :=> 'NotNull 'PGtext
   ]
:}

>>> :{
type EmailsTable =
  '[ "pk_emails" ::: 'PrimaryKey '["id"]
   , "fk_user_id" ::: 'ForeignKey '["user_id"] "users" '["id"]
   ] :=>
  '[ "id" ::: 'Def :=> 'NotNull 'PGint4
   , "user_id" ::: 'NoDef :=> 'NotNull 'PGint4
   , "email" ::: 'NoDef :=> 'Null 'PGtext
   ]
:}

Now we can define some `Migration`s to make our tables.

>>> :{
let
  makeUsers :: Migration (IsoQ Definition) (Public '[]) '["public" ::: '["users" ::: 'Table UsersTable]]
  makeUsers = Migration "make users table" IsoQ
    { up = createTable #users
        ( serial `as` #id :*
          notNullable text `as` #name )
        ( primaryKey #id `as` #pk_users )
    , down = dropTable #users
    }
:}

>>> :{
let
  makeEmails :: Migration (IsoQ Definition) '["public" ::: '["users" ::: 'Table UsersTable]]
    '["public" ::: '["users" ::: 'Table UsersTable, "emails" ::: 'Table EmailsTable]]
  makeEmails = Migration "make emails table" IsoQ
    { up = createTable #emails
          ( serial `as` #id :*
            notNullable int `as` #user_id :*
            nullable text `as` #email )
          ( primaryKey #id `as` #pk_emails :*
            foreignKey #user_id #users #id
              OnDeleteCascade OnUpdateCascade `as` #fk_user_id )
    , down = dropTable #emails
    }
:}

Now that we have a couple migrations we can chain them together into a `Path`.

>>> let migrations = makeUsers :>> makeEmails :>> Done

Now run the migrations.

>>> import Control.Monad.IO.Class
>>> :{
withConnection "host=localhost port=5432 dbname=exampledb" $
  manipulate (UnsafeManipulation "SET client_min_messages TO WARNING;")
    -- suppress notices
  & pqThen (liftIO (putStrLn "Migrate"))
  & pqThen (runIndexed (up (migrate migrations)))
  & pqThen (liftIO (putStrLn "Rollback"))
  & pqThen (runIndexed (down (migrate migrations)))
:}
Migrate
Rollback

We can also create a simple executable using `mainMigrateIso`.

>>> let main = mainMigrateIso "host=localhost port=5432 dbname=exampledb" migrations

>>> withArgs [] main
Invalid command: "". Use:
migrate    to run all available migrations
rollback   to rollback all available migrations
status     to display migrations run and migrations left to run

>>> withArgs ["status"] main
Migrations already run:
  None
Migrations left to run:
  - make users table
  - make emails table

>>> withArgs ["migrate"] main
Migrations already run:
  - make users table
  - make emails table
Migrations left to run:
  None

>>> withArgs ["rollback"] main
Migrations already run:
  None
Migrations left to run:
  - make users table
  - make emails table

In addition to enabling `Migration`s using pure SQL `Definition`s for
the `up` and `down` migrations, you can also perform impure `IO` actions
by using a `Migration`s over the `Indexed` `PQ` `IO` category.
-}

{-# LANGUAGE
    DataKinds
  , DeriveGeneric
  , FlexibleContexts
  , FlexibleInstances
  , FunctionalDependencies
  , GADTs
  , LambdaCase
  , MultiParamTypeClasses
  , OverloadedLabels
  , OverloadedStrings
  , PolyKinds
  , QuantifiedConstraints
  , RankNTypes
  , TypeApplications
  , TypeOperators
#-}

module Squeal.PostgreSQL.Migration
  ( -- * Migration
    Migration (..)
  , Migratory (..)
  , IsoQ (..)
  , MigrationsTable
  , mainMigrate
  , mainMigrateIso
  ) where

import Control.Category
import Control.Category.Free
import Control.Monad
import Data.ByteString (ByteString)
import Data.Foldable (traverse_)
import Data.Function ((&))
import Data.List ((\\))
import Data.Quiver
import Data.Quiver.Functor
import Data.Text (Text)
import Data.Time (UTCTime)
import Prelude hiding ((.), id)
import System.Environment
import UnliftIO (MonadIO (..))

import qualified Data.Text.IO as Text (putStrLn)
import qualified Generics.SOP as SOP
import qualified GHC.Generics as GHC

import Squeal.PostgreSQL.Alias
import Squeal.PostgreSQL.Binary
import Squeal.PostgreSQL.Definition
import Squeal.PostgreSQL.Definition.Table
import Squeal.PostgreSQL.Definition.Table.Column
import Squeal.PostgreSQL.Definition.Table.Constraint
import Squeal.PostgreSQL.Expression.Comparison
import Squeal.PostgreSQL.Expression.Parameter
import Squeal.PostgreSQL.Expression.Time
import Squeal.PostgreSQL.Expression.Type
import Squeal.PostgreSQL.List
import Squeal.PostgreSQL.Manipulation
import Squeal.PostgreSQL.PQ
import Squeal.PostgreSQL.Query
import Squeal.PostgreSQL.Schema
import Squeal.PostgreSQL.Transaction

-- | A `Migration` is a named "isomorphism" over a given category.
-- It should contain a migration and a unique `name`.
data Migration p schemas0 schemas1 = Migration
  { name :: Text -- ^ The `name` of a `Migration`.
    -- Each `name` in a `Migration` should be unique.
  , migration :: p schemas0 schemas1 -- ^ The migration of a `Migration`.
  } deriving (GHC.Generic)
instance CFunctor Migration where
  cmap f (Migration n i) = Migration n (f i)

{- |
A `Migratory` @p@ is a `Category` for which one can execute or
possibly rewind a `Path` of `Migration`s over @p@.
This includes the categories of pure SQL `Definition`s,
impure `Indexed` `PQ` `IO` @()@ actions,
and reversible `IsoQ` `Definition`s.
-}
class (Category def, Category run) => Migratory def run | def -> run where
  {- | Run a `Path` of `Migration`s.-}
  migrate :: Path (Migration def) schemas0 schemas1 -> run schemas0 schemas1
instance Migratory (Indexed PQ IO ()) (Indexed PQ IO ()) where
  migrate path = Indexed . unsafePQ . transactionally_ $ do
    define createMigrations
    ctoMonoid upMigration path
    where
      upMigration step = do
        executed <- do
          result <- runQueryParams selectMigration (Only (name step))
          ntuples result
        unless (executed == 1) $ do
          _ <- unsafePQ . runIndexed $ migration step
          manipulateParams_ insertMigration (Only (name step))
instance Migratory Definition (Indexed PQ IO ()) where
  migrate = migrate . cmap (cmap (Indexed @PQ @IO . define))
instance Migratory (OpQ (Indexed PQ IO ())) (OpQ (Indexed PQ IO ())) where
  migrate path = OpQ . Indexed . unsafePQ . transactionally_ $ do
    define createMigrations
    ctoMonoid @Path downMigration (creverse path)
    where
      downMigration (OpQ step) = do
        executed <- do
          result <- runQueryParams selectMigration (Only (name step))
          ntuples result
        unless (executed == 0) $ do
          _ <- unsafePQ . runIndexed . getOpQ $ migration step
          manipulateParams_ deleteMigration (Only (name step))
instance Migratory (OpQ Definition) (OpQ (Indexed PQ IO ())) where
  migrate = migrate . cmap (cmap (cmap (Indexed @PQ @IO . define)))
instance Migratory
  (IsoQ (Indexed PQ IO ()))
  (IsoQ (Indexed PQ IO ())) where
    migrate path = IsoQ
      (migrate (cmap (cmap up) path))
      (getOpQ (migrate (cmap (cmap (OpQ . down)) path)))
instance Migratory (IsoQ Definition) (IsoQ (Indexed PQ IO ())) where
  migrate = migrate . cmap (cmap (cmap (Indexed @PQ @IO . define)))

unsafePQ :: (Functor m) => PQ schemas0 schemas1 m x -> PQ schemas0' schemas1' m x
unsafePQ (PQ pq) = PQ $ fmap (SOP.K . SOP.unK) . pq . SOP.K . SOP.unK

-- | The `TableType` for a Squeal migration.
type MigrationsTable =
  '[ "migrations_unique_name" ::: 'Unique '["name"]] :=>
  '[ "name"        ::: 'NoDef :=> 'NotNull 'PGtext
   , "executed_at" :::   'Def :=> 'NotNull 'PGtimestamptz
   ]

data MigrationRow =
  MigrationRow { migrationName :: Text
               , migrationTime :: UTCTime }
  deriving (GHC.Generic, Show)

instance SOP.Generic MigrationRow
instance SOP.HasDatatypeInfo MigrationRow

type MigrationsSchema = '["schema_migrations" ::: 'Table MigrationsTable]
type MigrationsSchemas = Public MigrationsSchema

-- | Creates a `MigrationsTable` if it does not already exist.
createMigrations :: Definition MigrationsSchemas MigrationsSchemas
createMigrations =
  createTableIfNotExists #schema_migrations
    ( (text & notNullable) `as` #name :*
      (timestampWithTimeZone & notNullable & default_ currentTimestamp)
        `as` #executed_at )
    ( unique #name `as` #migrations_unique_name )

-- | Inserts a `Migration` into the `MigrationsTable`, returning
-- the time at which it was inserted.
insertMigration :: Manipulation_ MigrationsSchemas (Only Text) ()
insertMigration = insertInto_ #schema_migrations
  (Values_ (Set (param @1) `as` #name :* Default `as` #executed_at))

-- | Deletes a `Migration` from the `MigrationsTable`, returning
-- the time at which it was inserted.
deleteMigration :: Manipulation_ MigrationsSchemas (Only Text) ()
deleteMigration = deleteFrom_ #schema_migrations (#name .== param @1)

-- | Selects a `Migration` from the `MigrationsTable`, returning
-- the time at which it was inserted.
selectMigration
  :: Query_ MigrationsSchemas (Only Text) (Only UTCTime)
selectMigration = select_ (#executed_at `as` #fromOnly)
  $ from (table (#schema_migrations))
  & where_ (#name .== param @1)

selectMigrations :: Query_ MigrationsSchemas () MigrationRow
selectMigrations = select_
  (#name `as` #migrationName :* #executed_at `as` #migrationTime)
  (from (table #schema_migrations))

data MigrateCommand = MigrateStatus | Migrate
  deriving (GHC.Generic, Show)

{- | `mainMigrate` creates a simple executable
from a connection string and a `Path` of `Migration`s. -}
mainMigrate
  :: Migratory p (Indexed PQ IO ())
  => ByteString
  -- ^ connection string
  -> Path (Migration p) schemas0 schemas1
  -- ^ migrations
  -> IO ()
mainMigrate connectTo migrations = do
  command <- readCommandFromArgs
  maybe (pure ()) performCommand command

  where

    performCommand :: MigrateCommand -> IO ()
    performCommand = \case
      MigrateStatus -> withConnection connectTo $
        suppressNotices >> migrateStatus
      Migrate -> withConnection connectTo $
        suppressNotices
        & pqThen (runIndexed (migrate migrations))
        & pqThen migrateStatus

    migrateStatus :: PQ schema schema IO ()
    migrateStatus = unsafePQ $ do
      runNames <- getRunMigrationNames
      let names = ctoList name migrations
          unrunNames = names \\ runNames
      liftIO $ displayRunned runNames >> displayUnrunned unrunNames

    suppressNotices :: PQ schema schema IO ()
    suppressNotices = manipulate_ $
      UnsafeManipulation "SET client_min_messages TO WARNING;"

    readCommandFromArgs :: IO (Maybe MigrateCommand)
    readCommandFromArgs = getArgs >>= \case
      ["migrate"] -> pure . Just $ Migrate
      ["status"] -> pure . Just $ MigrateStatus
      args -> displayUsage args >> pure Nothing

    displayUsage :: [String] -> IO ()
    displayUsage args = do
      putStrLn $ "Invalid command: \"" <> unwords args <> "\". Use:"
      putStrLn "migrate    to run all available migrations"
      putStrLn "rollback   to rollback all available migrations"

    getRunMigrationNames :: (MonadIO m) => PQ schemas0 schemas0 m [Text]
    getRunMigrationNames =
      fmap migrationName <$>
      (unsafePQ (define createMigrations
      & pqThen (runQuery selectMigrations)) >>= getRows)

    displayListOfNames :: [Text] -> IO ()
    displayListOfNames [] = Text.putStrLn "  None"
    displayListOfNames xs =
      let singleName n = Text.putStrLn $ "  - " <> n
      in traverse_ singleName xs

    displayUnrunned :: [Text] -> IO ()
    displayUnrunned unrunned =
      Text.putStrLn "Migrations left to run:"
      >> displayListOfNames unrunned

    displayRunned :: [Text] -> IO ()
    displayRunned runned =
      Text.putStrLn "Migrations already run:"
      >> displayListOfNames runned

data MigrateIsoCommand
  = MigrateIsoStatus
  | MigrateIsoUp
  | MigrateIsoDown deriving (GHC.Generic, Show)

{- | `mainMigrateIso` creates a simple executable
from a connection string and a `Path` of `Migration` `Iso`s. -}
mainMigrateIso
  :: Migratory (IsoQ def) (IsoQ (Indexed PQ IO ()))
  => ByteString
  -- ^ connection string
  -> Path (Migration (IsoQ def)) schemas0 schemas1
  -- ^ migrations
  -> IO ()
mainMigrateIso connectTo migrations = do
  command <- readCommandFromArgs
  maybe (pure ()) performCommand command

  where

    performCommand :: MigrateIsoCommand -> IO ()
    performCommand = \case
      MigrateIsoStatus -> withConnection connectTo $
        suppressNotices >> migrateStatus
      MigrateIsoUp -> withConnection connectTo $
        suppressNotices
        & pqThen (runIndexed (up (migrate migrations)))
        & pqThen migrateStatus
      MigrateIsoDown -> withConnection connectTo $
        suppressNotices
        & pqThen (runIndexed (down (migrate migrations)))
        & pqThen migrateStatus

    migrateStatus :: PQ schema schema IO ()
    migrateStatus = unsafePQ $ do
      runNames <- getRunMigrationNames
      let names = ctoList name migrations
          unrunNames = names \\ runNames
      liftIO $ displayRunned runNames >> displayUnrunned unrunNames

    suppressNotices :: PQ schema schema IO ()
    suppressNotices = manipulate_ $
      UnsafeManipulation "SET client_min_messages TO WARNING;"

    readCommandFromArgs :: IO (Maybe MigrateIsoCommand)
    readCommandFromArgs = getArgs >>= \case
      ["migrate"] -> pure . Just $ MigrateIsoUp
      ["rollback"] -> pure . Just $ MigrateIsoDown
      ["status"] -> pure . Just $ MigrateIsoStatus
      args -> displayUsage args >> pure Nothing

    displayUsage :: [String] -> IO ()
    displayUsage args = do
      putStrLn $ "Invalid command: \"" <> unwords args <> "\". Use:"
      putStrLn "migrate    to run all available migrations"
      putStrLn "rollback   to rollback all available migrations"
      putStrLn "status     to display migrations run and migrations left to run"

    getRunMigrationNames :: (MonadIO m) => PQ schemas0 schemas0 m [Text]
    getRunMigrationNames =
      fmap migrationName <$>
        (unsafePQ (define createMigrations
        & pqThen (runQuery selectMigrations)) >>= getRows)

    displayListOfNames :: [Text] -> IO ()
    displayListOfNames [] = Text.putStrLn "  None"
    displayListOfNames xs =
      let singleName n = Text.putStrLn $ "  - " <> n
      in traverse_ singleName xs

    displayUnrunned :: [Text] -> IO ()
    displayUnrunned unrunned =
      Text.putStrLn "Migrations left to run:"
      >> displayListOfNames unrunned

    displayRunned :: [Text] -> IO ()
    displayRunned runned =
      Text.putStrLn "Migrations already run:"
      >> displayListOfNames runned
