{-# LANGUAGE CPP #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
#if __GLASGOW_HASKELL__ > 707
{-# LANGUAGE AllowAmbiguousTypes #-}
#endif

module Git.Types where

import qualified Control.Exception.Lifted as Exc
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BL
import           Data.Map (Map)
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Time
import           Data.Typeable
import           Pipes

type RawFilePath = ByteString

type RefName       = Text
type CommitAuthor  = Text
type CommitEmail   = Text
type CommitMessage = Text
type TreeFilePath  = RawFilePath

class (Eq (Oid r), Ord (Oid r), Show (Oid r)) => Repository r where
    data Oid r :: *      -- jww (2015-06-14): should be injective type family
    data Tree r :: *

-- type BlobOid r   = Tagged r (Oid r)
-- type TreeOid r   = Tagged (Tree r) (Oid r)
-- type CommitOid r = Tagged (Commit r) (Oid r)
-- type TagOid r    = Tagged (Tag r) (Oid r)

type BlobOid r   = Oid r
type TreeOid r   = Oid r
type CommitOid r = Oid r
type TagOid r    = Oid r

data ObjectOid r = BlobObjOid   !(BlobOid r)
                 | TreeObjOid   !(TreeOid r)
                 | CommitObjOid !(CommitOid r)
                 | TagObjOid    !(TagOid r)

instance Repository r => Show (ObjectOid r) where
    show (BlobObjOid   oid) = show oid
    show (TreeObjOid   oid) = show oid
    show (CommitObjOid oid) = show oid
    show (TagObjOid    oid) = show oid

{- $blobs -}
data Blob r m = Blob
    { blobOid      :: !(Oid r)
    , blobContents :: !(BlobContents m)
    }

type ByteSource m = Producer ByteString m ()

data BlobContents m = BlobString      !ByteString
                    | BlobStringLazy  !BL.ByteString
                    | BlobStream      !(ByteSource m)
                    | BlobSizedStream !(ByteSource m) !Int

data BlobKind = PlainBlob | ExecutableBlob | SymlinkBlob
              deriving (Show, Eq, Enum)

instance Eq (BlobContents m) where
  BlobString str1 == BlobString str2 = str1 == str2
  _ == _ = False

{- $trees -}
data TreeEntry r = BlobEntry   { blobEntryOid   :: !(Oid r)
                               , blobEntryKind  :: !BlobKind }
                 | TreeEntry   { treeEntryOid   :: !(Oid r) }
                 | CommitEntry { commitEntryOid :: !(Oid r) }

instance Repository r => Show (TreeEntry r) where
    show (BlobEntry oid _) = "<BlobEntry " ++ show oid ++ ">"
    show (TreeEntry oid)   = "<TreeEntry " ++ show oid ++ ">"
    show (CommitEntry oid) = "<CommitEntry " ++ show oid ++ ">"

treeEntryToOid :: TreeEntry r -> Oid r
treeEntryToOid (BlobEntry boid _) = boid
treeEntryToOid (TreeEntry toid)   = toid
treeEntryToOid (CommitEntry coid) = coid

{- $commits -}
data Commit r = Commit
    { commitOid       :: !(Oid r)
    , commitParents   :: ![Oid r]
    , commitTree      :: !(Oid r)
    , commitAuthor    :: !Signature
    , commitCommitter :: !Signature
    , commitLog       :: !CommitMessage
    , commitEncoding  :: !Text
    }

data Signature = Signature
    { signatureName  :: !CommitAuthor
    , signatureEmail :: !CommitEmail
    , signatureWhen  :: !ZonedTime
    } deriving Show

defaultSignature :: Signature
defaultSignature = Signature
    { signatureName  = T.empty
    , signatureEmail = T.empty
    , signatureWhen  = ZonedTime
        { zonedTimeToLocalTime = LocalTime
            { localDay = ModifiedJulianDay 0
            , localTimeOfDay = TimeOfDay 0 0 0
            }
        , zonedTimeZone = utc
        }
    }

{- $tags -}
data Tag r = Tag
    { tagOid      :: !(Oid r)
    , tagAuthor   :: !Signature
    , tagLog      :: !CommitMessage
    , tagEncoding :: !Text
    }

{- $objects -}
data Object r m = BlobObj   !(Blob r m)
                | TreeObj   !(Tree r)
                | CommitObj !(Commit r)
                | TagObj    !(Tag r)

{- $references -}
data RefTarget (r :: *) = RefObj !(Oid r) | RefSymbolic !RefName

instance Repository r => Show (RefTarget r) where
    show (RefObj oid)       = "RefObj#" ++ show oid
    show (RefSymbolic name) = "RefSymbolic#" ++ T.unpack name

commitRefTarget :: Commit r -> RefTarget r
commitRefTarget = RefObj . commitOid

{- $merges -}
data ModificationKind = Unchanged | Modified | Added | Deleted | TypeChanged
                      deriving (Eq, Ord, Enum, Show, Read)

data MergeStatus
    = NoConflict
    | BothModified
    | LeftModifiedRightDeleted
    | LeftDeletedRightModified
    | BothAdded
    | LeftModifiedRightTypeChanged
    | LeftTypeChangedRightModified
    | LeftDeletedRightTypeChanged
    | LeftTypeChangedRightDeleted
    | BothTypeChanged
    deriving (Eq, Ord, Enum, Show, Read)

mergeStatus :: ModificationKind -> ModificationKind -> MergeStatus
mergeStatus Unchanged Unchanged     = NoConflict
mergeStatus Unchanged Modified      = NoConflict
mergeStatus Unchanged Added         = undefined
mergeStatus Unchanged Deleted       = NoConflict
mergeStatus Unchanged TypeChanged   = NoConflict

mergeStatus Modified Unchanged      = NoConflict
mergeStatus Modified Modified       = BothModified
mergeStatus Modified Added          = undefined
mergeStatus Modified Deleted        = LeftModifiedRightDeleted
mergeStatus Modified TypeChanged    = LeftModifiedRightTypeChanged

mergeStatus Added Unchanged         = undefined
mergeStatus Added Modified          = undefined
mergeStatus Added Added             = BothAdded
mergeStatus Added Deleted           = undefined
mergeStatus Added TypeChanged       = undefined

mergeStatus Deleted Unchanged       = NoConflict
mergeStatus Deleted Modified        = LeftDeletedRightModified
mergeStatus Deleted Added           = undefined
mergeStatus Deleted Deleted         = NoConflict
mergeStatus Deleted TypeChanged     = LeftDeletedRightTypeChanged

mergeStatus TypeChanged Unchanged   = NoConflict
mergeStatus TypeChanged Modified    = LeftTypeChangedRightModified
mergeStatus TypeChanged Added       = undefined
mergeStatus TypeChanged Deleted     = LeftTypeChangedRightDeleted
mergeStatus TypeChanged TypeChanged = BothTypeChanged

data MergeResult r
    = MergeSuccess
        { mergeCommit    :: Oid r
        }
    | MergeConflicted
        { mergeCommit    :: Oid r
        , mergeHeadLeft  :: Oid r
        , mergeHeadRight :: Oid r
        , mergeConflicts ::
            Map TreeFilePath (ModificationKind, ModificationKind)
        }

instance Repository r => Show (MergeResult r) where
    show (MergeSuccess mc) =
        "MergeSuccess (" ++ show mc ++ ")"
    show (MergeConflicted mc hl hr cs) =
        "MergeResult"
     ++ "\n    { mergeCommit    = " ++ show mc
     ++ "\n    , mergeHeadLeft  = " ++ show hl
     ++ "\n    , mergeHeadRight = " ++ show hr
     ++ "\n    , mergeConflicts = " ++ show cs
     ++ "\n    }"

{- $exceptions -}
-- | There is a separate 'GitException' for each possible failure when
--   interacting with the Git repository.
data GitException
    = BackendError Text
    | GitError Text
    | RepositoryNotExist
    | RepositoryInvalid
    | RepositoryCannotAccess Text
    | BlobCreateFailed Text
    | BlobEmptyCreateFailed
    | BlobEncodingUnknown Text
    | BlobLookupFailed
    | DiffBlobFailed Text
    | DiffPrintToPatchFailed Text
    | DiffTreeToIndexFailed Text
    | IndexAddFailed TreeFilePath Text
    | IndexCreateFailed Text
    | PathEncodingError Text
    | PushNotFastForward Text
    | TagLookupFailed Text
    | TranslationException Text
    | TreeCreateFailed Text
    | TreeBuilderCreateFailed
    | TreeBuilderInsertFailed TreeFilePath
    | TreeBuilderRemoveFailed TreeFilePath
    | TreeBuilderWriteFailed Text
    | TreeLookupFailed
    | TreeCannotTraverseBlob
    | TreeCannotTraverseCommit
    | TreeEntryLookupFailed TreeFilePath
    | TreeUpdateFailed
    | TreeWalkFailed Text
    | TreeEmptyCreateFailed
    | CommitCreateFailed
    | CommitLookupFailed Text
    | ReferenceCreateFailed RefName
    | ReferenceDeleteFailed RefName
    | RefCannotCreateFromPartialOid
    | ReferenceListingFailed Text
    | ReferenceLookupFailed RefName
    | ObjectLookupFailed Text Int
    | ObjectRefRequiresFullOid
    | OidCopyFailed
    | OidParseFailed Text
    | QuotaHardLimitExceeded Int Int
    deriving (Eq, Show, Typeable)

-- jww (2013-02-11): Create a BackendException data constructor of forall
-- e. Exception e => BackendException e, so that each can throw a derived
-- exception.
instance Exc.Exception GitException
