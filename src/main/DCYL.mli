type 'a t
(** Work-stealing deque based on the Chase-Lev algorithm.

    Unlike the original Chase-Lev algorithm, this implementation does not have a
    limit on how many items may be pushed to and stolen from a deque as long as
    the elements fit into a single array at all times. *)

(** {2 For the owner}

    Only the owner may call the operations in this section. *)

val create : unit -> 'a t
(** Create a new work-stealing deque. *)

val push : 'a t -> 'a -> unit
(** Push a new element to the deque.

    Unlike the original Chase-Lev algorithm, {!push} never shrinks the internal
    storage capacity of the deque. *)

val pop : 'a t -> 'a
(** Attempt to pop an element from the deque.  Raises [Exit] if the deque is
    empty.

    If the deque is empty, {!pop} makes sure that the internal storage capacity
    of the deque is minimized. *)

(** {3 Dropping elements} *)

type pos
(** Position on a work-stealing deque. *)

val mark : 'a t -> pos
(** Get position of next {!push}. *)

val drop_at : 'a t -> pos -> unit
(** Attempt to pop (and discard) element from the deque in case the {!pos}ition
    afterwards is the same as given.  The position must be from the same deque.

    Like with the Chase-Lev algorithm, it is theoretically possible for the
    internal deque positions to wrap around.  In practice, however, it would
    take a very long for time for that to happen. *)

(** {2 For thieves}

    The operations in this section can also be safely called by the owner. *)

val steal : 'a t -> 'a
(** Attempt to remove an element from the deque.  Raises [Exit] if deque is
    empty. *)

val seems_empty : 'a t -> bool
(** Quickly approximate whether the queue seems empty.

    The result should be fairly accurate when called immediately after a
    {!steal} or {!pop} and could e.g. be used to decide whether it makes sense
    to spawn more thieves. *)
