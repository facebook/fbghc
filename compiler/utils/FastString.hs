-- (c) The University of Glasgow, 1997-2006

{-# LANGUAGE BangPatterns, CPP, MagicHash, UnboxedTuples,
    GeneralizedNewtypeDeriving #-}
{-# OPTIONS_GHC -O2 -funbox-strict-fields #-}
-- We always optimise this, otherwise performance of a non-optimised
-- compiler is severely affected

-- |
-- There are two principal string types used internally by GHC:
--
-- ['FastString']
--
--   * A compact, hash-consed, representation of character strings.
--   * Comparison is O(1), and you can get a 'Unique.Unique' from them.
--   * Generated by 'fsLit'.
--   * Turn into 'Outputable.SDoc' with 'Outputable.ftext'.
--
-- ['PtrString']
--
--   * Pointer and size of a Latin-1 encoded string.
--   * Practically no operations.
--   * Outputing them is fast.
--   * Generated by 'sLit'.
--   * Turn into 'Outputable.SDoc' with 'Outputable.ptext'
--   * Requires manual memory management.
--     Improper use may lead to memory leaks or dangling pointers.
--   * It assumes Latin-1 as the encoding, therefore it cannot represent
--     arbitrary Unicode strings.
--
-- Use 'PtrString' unless you want the facilities of 'FastString'.
module FastString
       (
        -- * ByteString
        fastStringToByteString,
        mkFastStringByteString,
        fastZStringToByteString,
        unsafeMkByteString,

        -- * FastZString
        FastZString,
        hPutFZS,
        zString,
        lengthFZS,

        -- * FastStrings
        FastString(..),     -- not abstract, for now.

        -- ** Construction
        fsLit,
        mkFastString,
        mkFastStringBytes,
        mkFastStringByteList,
        mkFastStringForeignPtr,
        mkFastString#,

        -- ** Deconstruction
        unpackFS,           -- :: FastString -> String
        bytesFS,            -- :: FastString -> [Word8]

        -- ** Encoding
        zEncodeFS,

        -- ** Operations
        uniqueOfFS,
        lengthFS,
        nullFS,
        appendFS,
        headFS,
        tailFS,
        concatFS,
        consFS,
        nilFS,

        -- ** Outputing
        hPutFS,

        -- ** Internal
        getFastStringTable,
        hasZEncoding,

        -- * PtrStrings
        PtrString (..),

        -- ** Construction
        sLit,
        mkPtrString#,
        mkPtrString,

        -- ** Deconstruction
        unpackPtrString,

        -- ** Operations
        lengthPS
       ) where

#include "HsVersions.h"

import GhcPrelude as Prelude

import Encoding
import FastFunctions
import Panic
import Util

import Control.Concurrent.MVar
import Control.DeepSeq
import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString          as BS
import qualified Data.ByteString.Char8    as BSC
import qualified Data.ByteString.Internal as BS
import qualified Data.ByteString.Unsafe   as BS
import Foreign.C
import GHC.Exts
import System.IO
import System.IO.Unsafe ( unsafePerformIO )
import Data.Data
import Data.IORef
import Data.Maybe       ( isJust )
import Data.Char
import Data.Semigroup as Semi

import GHC.IO           ( IO(..), unIO, unsafeDupablePerformIO )

import Foreign

#if STAGE >= 2
import GHC.Conc.Sync    (sharedCAF)
#endif

import GHC.Base         ( unpackCString#, unpackNBytes# )


fastStringToByteString :: FastString -> ByteString
fastStringToByteString f = fs_bs f

fastZStringToByteString :: FastZString -> ByteString
fastZStringToByteString (FastZString bs) = bs

-- This will drop information if any character > '\xFF'
unsafeMkByteString :: String -> ByteString
unsafeMkByteString = BSC.pack

hashFastString :: FastString -> Int
hashFastString (FastString _ _ bs _)
    = inlinePerformIO $ BS.unsafeUseAsCStringLen bs $ \(ptr, len) ->
      return $ hashStr (castPtr ptr) len

-- -----------------------------------------------------------------------------

newtype FastZString = FastZString ByteString
  deriving NFData

hPutFZS :: Handle -> FastZString -> IO ()
hPutFZS handle (FastZString bs) = BS.hPut handle bs

zString :: FastZString -> String
zString (FastZString bs) =
    inlinePerformIO $ BS.unsafeUseAsCStringLen bs peekCAStringLen

lengthFZS :: FastZString -> Int
lengthFZS (FastZString bs) = BS.length bs

mkFastZStringString :: String -> FastZString
mkFastZStringString str = FastZString (BSC.pack str)

-- -----------------------------------------------------------------------------

{-|
A 'FastString' is an array of bytes, hashed to support fast O(1)
comparison.  It is also associated with a character encoding, so that
we know how to convert a 'FastString' to the local encoding, or to the
Z-encoding used by the compiler internally.

'FastString's support a memoized conversion to the Z-encoding via zEncodeFS.
-}

data FastString = FastString {
      uniq    :: {-# UNPACK #-} !Int, -- unique id
      n_chars :: {-# UNPACK #-} !Int, -- number of chars
      fs_bs   :: {-# UNPACK #-} !ByteString,
      fs_ref  :: {-# UNPACK #-} !(IORef (Maybe FastZString))
  }

instance Eq FastString where
  f1 == f2  =  uniq f1 == uniq f2

instance Ord FastString where
    -- Compares lexicographically, not by unique
    a <= b = case cmpFS a b of { LT -> True;  EQ -> True;  GT -> False }
    a <  b = case cmpFS a b of { LT -> True;  EQ -> False; GT -> False }
    a >= b = case cmpFS a b of { LT -> False; EQ -> True;  GT -> True  }
    a >  b = case cmpFS a b of { LT -> False; EQ -> False; GT -> True  }
    max x y | x >= y    =  x
            | otherwise =  y
    min x y | x <= y    =  x
            | otherwise =  y
    compare a b = cmpFS a b

instance IsString FastString where
    fromString = fsLit

instance Semi.Semigroup FastString where
    (<>) = appendFS

instance Monoid FastString where
    mempty = nilFS
    mappend = (Semi.<>)
    mconcat = concatFS

instance Show FastString where
   show fs = show (unpackFS fs)

instance Data FastString where
  -- don't traverse?
  toConstr _   = abstractConstr "FastString"
  gunfold _ _  = error "gunfold"
  dataTypeOf _ = mkNoRepType "FastString"

cmpFS :: FastString -> FastString -> Ordering
cmpFS f1@(FastString u1 _ _ _) f2@(FastString u2 _ _ _) =
  if u1 == u2 then EQ else
  compare (fastStringToByteString f1) (fastStringToByteString f2)

foreign import ccall unsafe "memcmp"
  memcmp :: Ptr a -> Ptr b -> Int -> IO Int

-- -----------------------------------------------------------------------------
-- Construction

{-
Internally, the compiler will maintain a fast string symbol table, providing
sharing and fast comparison. Creation of new @FastString@s then covertly does a
lookup, re-using the @FastString@ if there was a hit.

The design of the FastString hash table allows for lockless concurrent reads
and updates to multiple buckets with low synchronization overhead.

See Note [Updating the FastString table] on how it's updated.
-}
data FastStringTable = FastStringTable
  {-# UNPACK #-} !(IORef Int) -- the unique ID counter shared with all buckets
  (Array# (IORef FastStringTableSegment)) -- concurrent segments

data FastStringTableSegment = FastStringTableSegment
  {-# UNPACK #-} !(MVar ()) -- the lock for write in each segment
  {-# UNPACK #-} !(IORef Int) -- the number of elements
  (MutableArray# RealWorld [FastString]) -- buckets in this segment

{-
Following parameters are determined based on:

* Benchmark based on testsuite/tests/utils/should_run/T14854.hs
* Stats of @echo :browse | ghc --interactive -dfaststring-stats >/dev/null@:
  on 2018-10-24, we have 13920 entries.
-}
segmentBits, numSegments, segmentMask, initialNumBuckets :: Int
segmentBits = 8
numSegments = 256   -- bit segmentBits
segmentMask = 0xff  -- bit segmentBits - 1
initialNumBuckets = 64

hashToSegment# :: Int# -> Int#
hashToSegment# hash# = hash# `andI#` segmentMask#
  where
    !(I# segmentMask#) = segmentMask

hashToIndex# :: MutableArray# RealWorld [FastString] -> Int# -> Int#
hashToIndex# buckets# hash# =
  (hash# `uncheckedIShiftRL#` segmentBits#) `remInt#` size#
  where
    !(I# segmentBits#) = segmentBits
    size# = sizeofMutableArray# buckets#

maybeResizeSegment :: IORef FastStringTableSegment -> IO FastStringTableSegment
maybeResizeSegment segmentRef = do
  segment@(FastStringTableSegment lock counter old#) <- readIORef segmentRef
  let oldSize# = sizeofMutableArray# old#
      newSize# = oldSize# *# 2#
  (I# n#) <- readIORef counter
  if isTrue# (n# <# newSize#) -- maximum load of 1
  then return segment
  else do
    resizedSegment@(FastStringTableSegment _ _ new#) <- IO $ \s1# ->
      case newArray# newSize# [] s1# of
        (# s2#, arr# #) -> (# s2#, FastStringTableSegment lock counter arr# #)
    forM_ [0 .. (I# oldSize#) - 1] $ \(I# i#) -> do
      fsList <- IO $ readArray# old# i#
      forM_ fsList $ \fs -> do
        let -- Shall we store in hash value in FastString instead?
            !(I# hash#) = hashFastString fs
            idx# = hashToIndex# new# hash#
        IO $ \s1# ->
          case readArray# new# idx# s1# of
            (# s2#, bucket #) -> case writeArray# new# idx# (fs: bucket) s2# of
              s3# -> (# s3#, () #)
    writeIORef segmentRef resizedSegment
    return resizedSegment

{-# NOINLINE stringTable #-}
stringTable :: FastStringTable
stringTable = unsafePerformIO $ do
  let !(I# numSegments#) = numSegments
      !(I# initialNumBuckets#) = initialNumBuckets
      loop a# i# s1#
        | isTrue# (i# ==# numSegments#) = s1#
        | otherwise = case newMVar () `unIO` s1# of
            (# s2#, lock #) -> case newIORef 0 `unIO` s2# of
              (# s3#, counter #) -> case newArray# initialNumBuckets# [] s3# of
                (# s4#, buckets# #) -> case newIORef
                    (FastStringTableSegment lock counter buckets#) `unIO` s4# of
                  (# s5#, segment #) -> case writeArray# a# i# segment s5# of
                    s6# -> loop a# (i# +# 1#) s6#
  uid <- newIORef 603979776 -- ord '$' * 0x01000000
  tab <- IO $ \s1# ->
    case newArray# numSegments# (panic "string_table") s1# of
      (# s2#, arr# #) -> case loop arr# 0# s2# of
        s3# -> case unsafeFreezeArray# arr# s3# of
          (# s4#, segments# #) -> (# s4#, FastStringTable uid segments# #)

  -- use the support wired into the RTS to share this CAF among all images of
  -- libHSghc
#if STAGE < 2
  return tab
#else
  sharedCAF tab getOrSetLibHSghcFastStringTable

-- from the RTS; thus we cannot use this mechanism when STAGE<2; the previous
-- RTS might not have this symbol
foreign import ccall unsafe "getOrSetLibHSghcFastStringTable"
  getOrSetLibHSghcFastStringTable :: Ptr a -> IO (Ptr a)
#endif

{-

We include the FastString table in the `sharedCAF` mechanism because we'd like
FastStrings created by a Core plugin to have the same uniques as corresponding
strings created by the host compiler itself.  For example, this allows plugins
to lookup known names (eg `mkTcOcc "MySpecialType"`) in the GlobalRdrEnv or
even re-invoke the parser.

In particular, the following little sanity test was failing in a plugin
prototyping safe newtype-coercions: GHC.NT.Type.NT was imported, but could not
be looked up /by the plugin/.

   let rdrName = mkModuleName "GHC.NT.Type" `mkRdrQual` mkTcOcc "NT"
   putMsgS $ showSDoc dflags $ ppr $ lookupGRE_RdrName rdrName $ mg_rdr_env guts

`mkTcOcc` involves the lookup (or creation) of a FastString.  Since the
plugin's FastString.string_table is empty, constructing the RdrName also
allocates new uniques for the FastStrings "GHC.NT.Type" and "NT".  These
uniques are almost certainly unequal to the ones that the host compiler
originally assigned to those FastStrings.  Thus the lookup fails since the
domain of the GlobalRdrEnv is affected by the RdrName's OccName's FastString's
unique.

Maintaining synchronization of the two instances of this global is rather
difficult because of the uses of `unsafePerformIO` in this module.  Not
synchronizing them risks breaking the rather major invariant that two
FastStrings with the same unique have the same string. Thus we use the
lower-level `sharedCAF` mechanism that relies on Globals.c.

-}

mkFastString# :: Addr# -> FastString
mkFastString# a# = mkFastStringBytes ptr (ptrStrLength ptr)
  where ptr = Ptr a#

{- Note [Updating the FastString table]

We use a concurrent hashtable which contains multiple segments, each hash value
always maps to the same segment. Read is lock-free, write to the a segment
should acquire a lock for that segment to avoid race condition, writes to
different segments are independent.

The procedure goes like this:

1. Find out which segment to operate on based on the hash value
2. Read the relevant bucket and perform a look up of the string.
3. If it exists, return it.
4. Otherwise grab a unique ID, create a new FastString and atomically attempt
   to update the relevant segment with this FastString:

   * Resize the segment by doubling the number of buckets when the number of
     FastStrings in this segment grows beyond the threshold.
   * Double check that the string is not in the bucket. Another thread may have
     inserted it while we were creating our string.
   * Return the existing FastString if it exists. The one we preemptively
     created will get GCed.
   * Otherwise, insert and return the string we created.
-}

mkFastStringWith :: (Int -> IO FastString) -> Ptr Word8 -> Int -> IO FastString
mkFastStringWith mk_fs !ptr !len = do
  FastStringTableSegment lock _ buckets# <- readIORef segmentRef
  let idx# = hashToIndex# buckets# hash#
  bucket <- IO $ readArray# buckets# idx#
  res <- bucket_match bucket len ptr
  case res of
    Just found -> return found
    Nothing -> do
      n <- get_uid
      new_fs <- mk_fs n
      withMVar lock $ \_ -> insert new_fs
  where
    !(FastStringTable uid segments#) = stringTable
    get_uid = atomicModifyIORef' uid $ \n -> (n+1,n)

    !(I# hash#) = hashStr ptr len
    (# segmentRef #) = indexArray# segments# (hashToSegment# hash#)
    insert fs = do
      FastStringTableSegment _ counter buckets# <- maybeResizeSegment segmentRef
      let idx# = hashToIndex# buckets# hash#
      bucket <- IO $ readArray# buckets# idx#
      res <- bucket_match bucket len ptr
      case res of
        -- The FastString was added by another thread after previous read and
        -- before we acquired the write lock.
        Just found -> return found
        Nothing -> do
          IO $ \s1# ->
            case writeArray# buckets# idx# (fs: bucket) s1# of
              s2# -> (# s2#, () #)
          modifyIORef' counter succ
          return fs

bucket_match :: [FastString] -> Int -> Ptr Word8 -> IO (Maybe FastString)
bucket_match [] _ _ = return Nothing
bucket_match (v@(FastString _ _ bs _):ls) len ptr
      | len == BS.length bs = do
         b <- BS.unsafeUseAsCString bs $ \buf ->
             cmpStringPrefix ptr (castPtr buf) len
         if b then return (Just v)
              else bucket_match ls len ptr
      | otherwise =
         bucket_match ls len ptr

mkFastStringBytes :: Ptr Word8 -> Int -> FastString
mkFastStringBytes !ptr !len =
    -- NB: Might as well use unsafeDupablePerformIO, since mkFastStringWith is
    -- idempotent.
    unsafeDupablePerformIO $
        mkFastStringWith (copyNewFastString ptr len) ptr len

-- | Create a 'FastString' from an existing 'ForeignPtr'; the difference
-- between this and 'mkFastStringBytes' is that we don't have to copy
-- the bytes if the string is new to the table.
mkFastStringForeignPtr :: Ptr Word8 -> ForeignPtr Word8 -> Int -> IO FastString
mkFastStringForeignPtr ptr !fp len
    = mkFastStringWith (mkNewFastString fp ptr len) ptr len

-- | Create a 'FastString' from an existing 'ForeignPtr'; the difference
-- between this and 'mkFastStringBytes' is that we don't have to copy
-- the bytes if the string is new to the table.
mkFastStringByteString :: ByteString -> FastString
mkFastStringByteString bs =
    inlinePerformIO $
      BS.unsafeUseAsCStringLen bs $ \(ptr, len) -> do
        let ptr' = castPtr ptr
        mkFastStringWith (mkNewFastStringByteString bs ptr' len) ptr' len

-- | Creates a UTF-8 encoded 'FastString' from a 'String'
mkFastString :: String -> FastString
mkFastString str =
  inlinePerformIO $ do
    let l = utf8EncodedLength str
    buf <- mallocForeignPtrBytes l
    withForeignPtr buf $ \ptr -> do
      utf8EncodeString ptr str
      mkFastStringForeignPtr ptr buf l

-- | Creates a 'FastString' from a UTF-8 encoded @[Word8]@
mkFastStringByteList :: [Word8] -> FastString
mkFastStringByteList str =
  inlinePerformIO $ do
    let l = Prelude.length str
    buf <- mallocForeignPtrBytes l
    withForeignPtr buf $ \ptr -> do
      pokeArray (castPtr ptr) str
      mkFastStringForeignPtr ptr buf l

-- | Creates a Z-encoded 'FastString' from a 'String'
mkZFastString :: String -> FastZString
mkZFastString = mkFastZStringString

mkNewFastString :: ForeignPtr Word8 -> Ptr Word8 -> Int -> Int
                -> IO FastString
mkNewFastString fp ptr len uid = do
  ref <- newIORef Nothing
  n_chars <- countUTF8Chars ptr len
  return (FastString uid n_chars (BS.fromForeignPtr fp 0 len) ref)

mkNewFastStringByteString :: ByteString -> Ptr Word8 -> Int -> Int
                          -> IO FastString
mkNewFastStringByteString bs ptr len uid = do
  ref <- newIORef Nothing
  n_chars <- countUTF8Chars ptr len
  return (FastString uid n_chars bs ref)

copyNewFastString :: Ptr Word8 -> Int -> Int -> IO FastString
copyNewFastString ptr len uid = do
  fp <- copyBytesToForeignPtr ptr len
  ref <- newIORef Nothing
  n_chars <- countUTF8Chars ptr len
  return (FastString uid n_chars (BS.fromForeignPtr fp 0 len) ref)

copyBytesToForeignPtr :: Ptr Word8 -> Int -> IO (ForeignPtr Word8)
copyBytesToForeignPtr ptr len = do
  fp <- mallocForeignPtrBytes len
  withForeignPtr fp $ \ptr' -> copyBytes ptr' ptr len
  return fp

cmpStringPrefix :: Ptr Word8 -> Ptr Word8 -> Int -> IO Bool
cmpStringPrefix ptr1 ptr2 len =
 do r <- memcmp ptr1 ptr2 len
    return (r == 0)


hashStr  :: Ptr Word8 -> Int -> Int
 -- use the Addr to produce a hash value between 0 & m (inclusive)
hashStr (Ptr a#) (I# len#) = loop 0# 0#
   where
    loop h n | isTrue# (n ==# len#) = I# h
             | otherwise  = loop h2 (n +# 1#)
          where
            !c = ord# (indexCharOffAddr# a# n)
            !h2 = (h *# 16777619#) `xorI#` c

-- -----------------------------------------------------------------------------
-- Operations

-- | Returns the length of the 'FastString' in characters
lengthFS :: FastString -> Int
lengthFS f = n_chars f

-- | Returns @True@ if this 'FastString' is not Z-encoded but already has
-- a Z-encoding cached (used in producing stats).
hasZEncoding :: FastString -> Bool
hasZEncoding (FastString _ _ _ ref) =
      inlinePerformIO $ do
        m <- readIORef ref
        return (isJust m)

-- | Returns @True@ if the 'FastString' is empty
nullFS :: FastString -> Bool
nullFS f = BS.null (fs_bs f)

-- | Unpacks and decodes the FastString
unpackFS :: FastString -> String
unpackFS (FastString _ _ bs _) = utf8DecodeByteString bs

-- | Gives the UTF-8 encoded bytes corresponding to a 'FastString'
bytesFS :: FastString -> [Word8]
bytesFS fs = BS.unpack $ fastStringToByteString fs

-- | Returns a Z-encoded version of a 'FastString'.  This might be the
-- original, if it was already Z-encoded.  The first time this
-- function is applied to a particular 'FastString', the results are
-- memoized.
--
zEncodeFS :: FastString -> FastZString
zEncodeFS fs@(FastString _ _ _ ref) =
      inlinePerformIO $ do
        m <- readIORef ref
        case m of
          Just zfs -> return zfs
          Nothing -> do
            atomicModifyIORef' ref $ \m' -> case m' of
              Nothing  -> let zfs = mkZFastString (zEncodeString (unpackFS fs))
                          in (Just zfs, zfs)
              Just zfs -> (m', zfs)

appendFS :: FastString -> FastString -> FastString
appendFS fs1 fs2 = mkFastStringByteString
                 $ BS.append (fastStringToByteString fs1)
                             (fastStringToByteString fs2)

concatFS :: [FastString] -> FastString
concatFS = mkFastStringByteString . BS.concat . map fs_bs

headFS :: FastString -> Char
headFS (FastString _ 0 _ _) = panic "headFS: Empty FastString"
headFS (FastString _ _ bs _) =
  inlinePerformIO $ BS.unsafeUseAsCString bs $ \ptr ->
         return (fst (utf8DecodeChar (castPtr ptr)))

tailFS :: FastString -> FastString
tailFS (FastString _ 0 _ _) = panic "tailFS: Empty FastString"
tailFS (FastString _ _ bs _) =
    inlinePerformIO $ BS.unsafeUseAsCString bs $ \ptr ->
    do let (_, n) = utf8DecodeChar (castPtr ptr)
       return $! mkFastStringByteString (BS.drop n bs)

consFS :: Char -> FastString -> FastString
consFS c fs = mkFastString (c : unpackFS fs)

uniqueOfFS :: FastString -> Int
uniqueOfFS (FastString u _ _ _) = u

nilFS :: FastString
nilFS = mkFastString ""

-- -----------------------------------------------------------------------------
-- Stats

getFastStringTable :: IO [[[FastString]]]
getFastStringTable =
  forM [0 .. numSegments - 1] $ \(I# i#) -> do
    let (# segmentRef #) = indexArray# segments# i#
    FastStringTableSegment _ _ buckets# <- readIORef segmentRef
    let bucketSize = I# (sizeofMutableArray# buckets#)
    forM [0 .. bucketSize - 1] $ \(I# j#) ->
      IO $ readArray# buckets# j#
  where
    !(FastStringTable _ segments#) = stringTable

-- -----------------------------------------------------------------------------
-- Outputting 'FastString's

-- |Outputs a 'FastString' with /no decoding at all/, that is, you
-- get the actual bytes in the 'FastString' written to the 'Handle'.
hPutFS :: Handle -> FastString -> IO ()
hPutFS handle fs = BS.hPut handle $ fastStringToByteString fs

-- ToDo: we'll probably want an hPutFSLocal, or something, to output
-- in the current locale's encoding (for error messages and suchlike).

-- -----------------------------------------------------------------------------
-- PtrStrings, here for convenience only.

-- | A 'PtrString' is a pointer to some array of Latin-1 encoded chars.
data PtrString = PtrString !(Ptr Word8) !Int

-- | Wrap an unboxed address into a 'PtrString'.
mkPtrString# :: Addr# -> PtrString
mkPtrString# a# = PtrString (Ptr a#) (ptrStrLength (Ptr a#))

-- | Encode a 'String' into a newly allocated 'PtrString' using Latin-1
-- encoding.  The original string must not contain non-Latin-1 characters
-- (above codepoint @0xff@).
{-# INLINE mkPtrString #-}
mkPtrString :: String -> PtrString
mkPtrString s =
 -- we don't use `unsafeDupablePerformIO` here to avoid potential memory leaks
 -- and because someone might be using `eqAddr#` to check for string equality.
 unsafePerformIO (do
   let len = length s
   p <- mallocBytes len
   let
     loop :: Int -> String -> IO ()
     loop !_ []    = return ()
     loop n (c:cs) = do
        pokeByteOff p n (fromIntegral (ord c) :: Word8)
        loop (1+n) cs
   loop 0 s
   return (PtrString p len)
 )

-- | Decode a 'PtrString' back into a 'String' using Latin-1 encoding.
-- This does not free the memory associated with 'PtrString'.
unpackPtrString :: PtrString -> String
unpackPtrString (PtrString (Ptr p#) (I# n#)) = unpackNBytes# p# n#

-- | Return the length of a 'PtrString'
lengthPS :: PtrString -> Int
lengthPS (PtrString _ n) = n

-- -----------------------------------------------------------------------------
-- under the carpet

foreign import ccall unsafe "strlen"
  ptrStrLength :: Ptr Word8 -> Int

{-# NOINLINE sLit #-}
sLit :: String -> PtrString
sLit x  = mkPtrString x

{-# NOINLINE fsLit #-}
fsLit :: String -> FastString
fsLit x = mkFastString x

{-# RULES "slit"
    forall x . sLit  (unpackCString# x) = mkPtrString#  x #-}
{-# RULES "fslit"
    forall x . fsLit (unpackCString# x) = mkFastString# x #-}
