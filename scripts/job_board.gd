extends Node

# THE JOB BOARD: the hook the next prompts plug roles and designated tasks into, WITHOUT rewriting the colonist AI.
#
# Where it sits in the colonist's decisions (highest first; see colonist_orders.gd):
#   1. carrying the toolbox with the player          (Colonist.State.HELPING_CARRY, not the board's business)
#   2. survival needs: eat, sleep                     (Colonist._schedule_tick, runs before everything below)
#   3. JOBS from this board                           <- ColonistOrderAI.tick() asks board.best_for(colonist) first
#   4. the stance (follow / assist / stay / free)     (ColonistOrderAI)
# A colonist with no stance work still asks the board: a FREE colonist is also "ordered" the moment a job exists for him
# (the next prompt wires that in Colonist._process: `if job != null: state = ORDERED`).
#
# A JOB is a small object (subclass Job below) with:
#   type      : StringName      what kind of work ("chop", "haul", "till" ...)
#   target    : Node/Variant    what it is done to (a tree, a blueprint, a plot cell ...)
#   priority  : int             higher first; ties go to the nearest colonist
#   can_do(colonist) -> bool    is he allowed and able (his roles, tools, tiredness, the target still valid)
#   claim(colonist) -> bool     reserve the target for him (use the target's own try_claim; never leave a claim behind)
#   release()                   give every claim back (called on completion, on an interrupt, when he dies)
#   execute(colonist, delta) -> bool   one frame of the work; true when the job is finished
#   describe() -> String        "Chopping an oak" (for the hover overlay and the Orders panel)
#
# A job in progress is stored on the colonist as `order_ai.board_job`; the AI calls release() whenever the colonist leaves
# State.ORDERED (a need, the carry, death), so a claim can never stay behind. Designated tasks (Colonist.orders.tasks) and
# roles (orders.roles) are the data a board uses to decide who may take which job.
#
# The roles and designated tasks of the Orders panel are the first users: pick_for() asks work_jobs.gd (tasks, then roles). Jobs posted
# on the board by anything else (post()) are looked at first.

class Job extends RefCounted:
	var type: StringName = &""
	var target = null
	var priority: int = 0
	var claimed_by = null
	func can_do(_colonist) -> bool:
		return false
	func claim(colonist) -> bool:
		claimed_by = colonist
		return true
	func release() -> void:
		claimed_by = null
	func execute(_colonist, _delta: float) -> bool:
		return true
	func describe() -> String:
		return String(type)

var jobs: Array = []

func _ready() -> void:
	add_to_group("job_board")

func post(job: Job) -> void:
	jobs.append(job)

func remove(job: Job) -> void:
	job.release()
	jobs.erase(job)

# The next job for a colonist, claimed and ready (a posted job, else a task or role job), or null.
func pick_for(colonist) -> Job:
	var posted: Job = best_for(colonist)
	if posted != null and posted.claim(colonist):
		return posted
	return load("res://scripts/work_jobs.gd").pick(colonist)

# The best open job this colonist may take now (highest priority first), or null.
func best_for(colonist) -> Job:
	var best: Job = null
	for job in jobs:
		if job.claimed_by != null and job.claimed_by != colonist:
			continue
		if not job.can_do(colonist):
			continue
		if best == null or job.priority > best.priority:
			best = job
	return best
