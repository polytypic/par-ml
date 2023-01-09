type 'a t
(** Work-stealing deque. *)

type pos
(** Position on a work-stealing deque. *)

exception Empty
(** Raised by [pop] and [steal] in case deque is empty. *)

val make : unit -> 'a t
(** Create a new work-stealing deque. *)

val push : 'a t -> 'a -> unit
(** Push new element to deque.  Only the owner may call this. *)

val pop : 'a t -> 'a
(** Attempt to pop element of deque.  Raises [Empty] if deque is empty.  Only
    the owner may call this. *)

val mark : 'a t -> pos
(** Get position of next [push]. *)

val drop_at : 'a t -> pos -> unit
(** Attempt to drop element at given position from the deque.  Only the owner
    may call this and the position must be from the deque. *)

val steal : 'a t -> 'a
(** Attempt to remove an element from the deque.  Raises [Empty] if deque is
    empty. *)
