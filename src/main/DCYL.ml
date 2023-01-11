(* Based on circular work-stealing deque of David Chase and Yossi Lev.

   For clarity, this renames `top` and `bottom` to `lo` and `hi` such that
   `hi - lo` is positive in case the deque is non-empty.

   Thieves (and owner) update `lo` when stealing elements from the `lo` end
   of the deque.  The owner maintains a separate `lo_cache`.  This is done to
   allow the owner to clear (or release) stolen elements for GC to work.  It
   is not safe for thieves to write to the `elems` array of the deque. *)

[@@@ocaml.warning "-69"] (* Disable unused field warning. *)

open Util

type 'a t = {
  lo : int Atomic.t;
  (* Only the owner mutates the rest: *)
  mutable elems : 'a array;
  m2 : int;
  m3 : int;
  m4 : int;
  m5 : int;
  m6 : int;
  m7 : int;
  m8 : int;
  m9 : int;
  mA : int;
  mB : int;
  mC : int;
  mD : int;
  mE : int;
  mF : int;
  mutable lo_cache : int;
  mutable hi : int;
}

type pos = int

exception Empty

let mask_of array =
  (* The original unpadded array length must be a power of two. *)
  Multicore.length_of_padded_array_minus_1 array
  [@@inline]

let make () =
  Multicore.copy_as_padded
    {
      lo = Multicore.copy_as_padded (Atomic.make 0);
      elems = Multicore.make_padded_array 16 (null ());
      m2 = 0;
      m3 = 0;
      m4 = 0;
      m5 = 0;
      m6 = 0;
      m7 = 0;
      m8 = 0;
      m9 = 0;
      mA = 0;
      mB = 0;
      mC = 0;
      mD = 0;
      mE = 0;
      mF = 0;
      lo_cache = 0;
      hi = 0;
    }

(* This writes `null ()` over stolen elements to allow GC to work.  This is
   called by the owner from `push`, `pop` and `drop_at` when the `lo_cache` is
   not equal to `lo`. *)
let clear_stolen dcyl lo =
  let elems = dcyl.elems in
  let mask = mask_of elems in
  for i = dcyl.lo_cache to lo - 1 do
    Array.unsafe_set elems (i land mask) (null ())
  done;
  dcyl.lo_cache <- lo

let grow dcyl =
  let elems = dcyl.elems in
  let mask = mask_of elems in
  let mask' = (mask * 2) + 1 in
  let elems' = Multicore.make_padded_array (mask' + 1) (null ()) in
  let lo = Atomic.get dcyl.lo in
  for i = lo to dcyl.hi - 1 do
    Array.unsafe_set elems' (i land mask')
      (Array.unsafe_get elems (i land mask))
  done;
  dcyl.elems <- elems'

let mark dcyl = dcyl.hi [@@inline]

let push dcyl elem =
  let hi = dcyl.hi in
  let elems = dcyl.elems in
  let mask = mask_of elems in
  let lo = dcyl.lo_cache in
  if hi - lo < mask then begin
    Array.unsafe_set elems (hi land mask) elem;
    (* Ensure `elem` is written before `hi` so thieves read valid elems. *)
    Atomic.fence dcyl.lo;
    (* Thieves may read old value of `hi`, but that should be safe. *)
    dcyl.hi <- hi + 1
  end
  else begin
    let lo = Atomic.get dcyl.lo in
    if dcyl.lo_cache <> lo then clear_stolen dcyl lo else grow dcyl;
    (* Either case we now know there is space for a new elem. *)
    let elems = dcyl.elems in
    let mask = mask_of elems in
    Array.unsafe_set elems (hi land mask) elem;
    (* Ensure `elem` is written before `hi` so thieves read valid elems. *)
    Atomic.fence dcyl.lo;
    (* Thieves may read old value of `hi`, but that should be safe. *)
    dcyl.hi <- hi + 1
  end
  [@@inline]

let pop dcyl =
  let hi = dcyl.hi - 1 in
  dcyl.hi <- hi;
  (* Ensure `hi` is written before reading `lo` to stop thieves. *)
  let lo = Atomic.fetch_and_add dcyl.lo 0 in
  if dcyl.lo_cache <> lo then clear_stolen dcyl lo;
  if hi < lo then begin
    dcyl.hi <- hi + 1;
    raise Empty
  end
  else
    let elems = dcyl.elems in
    let mask = mask_of elems in
    let i = hi land mask in
    let elem = Array.unsafe_get elems i in
    if lo < hi then begin
      Array.unsafe_set elems i (null ());
      elem
    end
    else
      (* Compete with thieves for last element. *)
      let got = Atomic.compare_and_set dcyl.lo lo (lo + 1) in
      dcyl.hi <- hi + 1;
      if got then elem else raise Empty

let drop_at dcyl at =
  let hi = dcyl.hi - 1 in
  if hi = at then begin
    dcyl.hi <- hi;
    (* Ensure `hi` is written before reading `lo` to stop thieves. *)
    let lo = Atomic.fetch_and_add dcyl.lo 0 in
    if dcyl.lo_cache <> lo then clear_stolen dcyl lo;
    if hi < lo then dcyl.hi <- hi + 1
    else
      let elems = dcyl.elems in
      let mask = mask_of elems in
      if lo < hi then Array.unsafe_set elems (hi land mask) (null ())
      else begin
        (* Compete with thieves for last element. *)
        Atomic.compare_and_set dcyl.lo lo (lo + 1) |> ignore;
        dcyl.hi <- hi + 1
      end
  end

let rec steal dcyl =
  let lo = Atomic.get dcyl.lo in
  (* Read `lo` before `hi` and `elems` access so that... *)
  if dcyl.hi <= lo then raise Empty
  else
    (* ...at this point the `elems` access is safe. *)
    let elems = dcyl.elems in
    let elem = Array.unsafe_get elems (lo land mask_of elems) in
    if Atomic.compare_and_set dcyl.lo lo (lo + 1) then
      (* Unsafe to write `null ()` over elem here, see `clear_stolen`. *)
      elem
    else steal dcyl
