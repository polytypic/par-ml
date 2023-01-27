(* Based on circular work-stealing deque of David Chase and Yossi Lev.

   For clarity, this renames `top` and `bottom` to `lo` and `hi` such that
   `hi - lo` is positive in case the deque is non-empty.

   Thieves (and owner) update `lo` when stealing elements from the `lo` end
   of the deque.  The owner maintains a separate `lo_cache`.  This is done to
   allow the owner to clear (or release) stolen elements for GC to work.  It
   is not safe for thieves to write to the `elems` array of the deque. *)

[@@@ocaml.warning "-69"] (* Disable unused field warning. *)

type 'a t = {
  lo : int Atomic.t;
  (* Only the owner mutates the rest: *)
  hi : int Atomic.t;
  mutable elems : 'a array;
  mutable lo_cache : int;
}

type pos = int

let min_capacity = 4

let mask_of array =
  (* The original unpadded array length must be a power of two. *)
  Multicore_magic.length_of_padded_array_minus_1 array
  [@@inline]

let create () =
  Multicore_magic.copy_as_padded
    {
      lo = Multicore_magic.copy_as_padded (Atomic.make 0);
      hi = Multicore_magic.copy_as_padded (Atomic.make 0);
      elems = Multicore_magic.make_padded_array min_capacity (Obj.magic ());
      lo_cache = 0;
    }

let mark t = Multicore_magic.fenceless_get t.hi [@@inline]

let clear ~elems ~mask ~start ~stop =
  let n = stop - start in
  let i = start land mask in
  let length = mask + 1 in
  let m = Int.min (length - i) n in
  Array.fill elems i m (Obj.magic ());
  Array.fill elems 0 (n - m) (Obj.magic ())

let double ~elems ~mask ~elems' ~mask' ~start =
  let i = start land mask in
  let length = mask + 1 in
  let m = length - i in
  Array.blit elems i elems' (start land mask') m;
  Array.blit elems 0 elems' ((start + m) land mask') (length - m)
  [@@inline]

let clear_or_double_and_push t elem =
  let lo = Multicore_magic.fenceless_get t.lo in
  (* `fenceless_get lo` is safe as we do not need the latest value. *)
  let elems = t.elems in
  let mask = mask_of elems in
  let lo_cache = t.lo_cache in
  if lo_cache <> lo then begin
    (* We know that `lo_cache = hi`. *)
    Array.unsafe_set elems (lo_cache land mask) elem;
    (* Publish the new element first. *)
    Atomic.incr t.hi;
    (* `incr` ensures elem is seen before `hi` and thieves read valid. *)
    t.lo_cache <- lo;
    (* Clear stolen elements last. *)
    clear ~elems ~mask ~start:(lo_cache + 1) ~stop:lo
  end
  else begin
    (* Double to make room. *)
    let hi = Multicore_magic.fenceless_get t.hi in
    (* `fenceless_get hi` is safe as only the owner mutates `hi`. *)
    let mask' = (mask * 2) + 1 in
    let elems' = Multicore_magic.make_padded_array (mask' + 1) (Obj.magic ()) in
    double ~elems ~mask ~elems' ~mask' ~start:lo;
    Array.unsafe_set elems' (hi land mask') elem;
    Multicore_magic.fence t.hi;
    (* `fence` ensures `elems'` is filled before publishing it. *)
    t.elems <- elems';
    Atomic.incr t.hi
    (* `incr` ensures elem is seen before `hi` and thieves read valid. *)
  end
  [@@inline never]

let push t elem =
  let hi = Multicore_magic.fenceless_get t.hi in
  (* `fenceless_get hi` is safe as only the owner mutates `hi`. *)
  let elems = t.elems in
  let mask = mask_of elems in
  let lo_cache = t.lo_cache in
  if hi - lo_cache <= mask then begin
    Array.unsafe_set elems (hi land mask) elem;
    Atomic.incr t.hi
    (* `incr` ensures elem is seen before `hi` and thieves read valid. *)
  end
  else clear_or_double_and_push t elem
  [@@inline]

let reset_and_exit t elems lo =
  if Multicore_magic.length_of_padded_array elems <> min_capacity then begin
    t.lo_cache <- lo;
    t.elems <- Multicore_magic.make_padded_array min_capacity (Obj.magic ())
  end
  else begin
    let lo_cache = t.lo_cache in
    if lo_cache <> lo then begin
      t.lo_cache <- lo;
      let mask = mask_of elems in
      clear ~elems ~mask ~start:lo_cache ~stop:lo
    end
  end;
  raise Exit

let pop t =
  let hi = Atomic.fetch_and_add t.hi (-1) - 1 in
  (* `fetch_and_add hi` ensures `hi` is written first to stop thieves. *)
  let lo = Multicore_magic.fenceless_get t.lo in
  (* `fenceless_get lo` is safe as we do not need the latest value. *)
  let n = hi - lo in
  if n < 0 then begin
    Multicore_magic.fenceless_set t.hi (hi + 1);
    (* `fenceless_set hi` is safe as old value is safe for thieves. *)
    reset_and_exit t t.elems lo
  end
  else
    let elems = t.elems in
    let mask = mask_of elems in
    let i = hi land mask in
    let elem = Array.unsafe_get elems i in
    if 0 < n then begin
      Array.unsafe_set elems i (Obj.magic ());
      elem
    end
    else
      (* Compete with thieves for last element. *)
      let got = Atomic.compare_and_set t.lo lo (lo + 1) in
      Multicore_magic.fenceless_set t.hi (hi + 1);
      (* `fenceless_set hi` is safe as old value is safe for thieves. *)
      if got then elem else reset_and_exit t elems lo

let drop_at t at =
  let hi = Multicore_magic.fenceless_get t.hi - 1 in
  if hi = at then begin
    Atomic.decr t.hi;
    (* `decr hi` ensures `hi` is written first to stop thieves. *)
    let lo = Multicore_magic.fenceless_get t.lo in
    (* `fenceless_get lo` is safe as we do not need the latest value. *)
    let n = hi - lo in
    if n < 0 then Multicore_magic.fenceless_set t.hi (hi + 1)
      (* `fenceless_set hi` is safe as old value is safe for thieves. *)
    else
      let elems = t.elems in
      let mask = mask_of elems in
      if 0 < n then Array.unsafe_set elems (hi land mask) (Obj.magic ())
      else begin
        (* Compete with thieves for last element. *)
        Atomic.compare_and_set t.lo lo (lo + 1) |> ignore;
        Multicore_magic.fenceless_set t.hi (hi + 1)
        (* `fenceless_set hi` is safe as old value is safe for thieves. *)
      end
  end

let rec steal t =
  let lo = Multicore_magic.fenceless_get t.lo in
  (* `fenceless_get lo` is safe as it is verified by `compare_and_set lo`. *)
  let n = Atomic.get t.hi - lo in
  (* `get hi` ensures the `t.elems` access below is safe. *)
  if n <= 0 then raise Exit
  else
    let elems = t.elems in
    let elem = Array.unsafe_get elems (lo land mask_of elems) in
    if Atomic.compare_and_set t.lo lo (lo + 1) then
      (* Unsafe to write `Obj.magic ()` over elem here. *)
      elem
    else steal t

let seems_empty t =
  Multicore_magic.fenceless_get t.hi - Multicore_magic.fenceless_get t.lo <= 0
  [@@inline]
