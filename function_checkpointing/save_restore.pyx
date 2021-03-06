from typing import Generator, List, Tuple, Sequence
import collections
import dis
import logging

from function_checkpointing.jump cimport *

SavedStackFrame = collections.namedtuple(
        'SavedStackFrame',
        ('f_lasti', 'stack_content', 'co_code', 'try_block_stack'),
        module=__name__
        )

class NULLObject(object):
    pass

log = logging.getLogger(__name__)


def loop_nesting_level(instructions: Sequence[dis.Instruction],
        starting_from: int, ending_at: int = None) -> int:
    """Count the level of nesting of for loops surrounding the given range of
    instructions."""

    if ending_at is None:
        ending_at = starting_from

    # Find the first backward jump after this range
    while ending_at < len(instructions):
        if instructions[ending_at].opcode == JUMP_ABSOLUTE:
            break
        ending_at += 1
    else:
        # No loop of any kind encloses the block
        return 0

    # The index into `instructions` this jumps to.
    jump_target: int = instructions[ending_at].arg // 2


    # If the jump encompasses the target block and it jumps to a FOR_ITER instruction,
    # then this block is inside a for loop.
    if jump_target < starting_from and instructions[jump_target].opcode == FOR_ITER:
        # Now check if that for loop is itself inside another for loop.
        return 1 + loop_nesting_level(instructions, jump_target - 1, ending_at + 1)

    # This jump wasn't part of a for loop that enclosed us. But there might be
    # jump instruction later that that encompasses this block.
    return loop_nesting_level(instructions, starting_from, ending_at + 1)


cdef object snapshot_frame(PyFrameObject *frame):
    log.debug('Saving frame %s(co_argcount=%d) last_i=%d',
        <object>frame.f_code.co_name,
        <object>frame.f_code.co_argcount,
        <object>frame.f_lasti)

    # The stack contains the the local variables, but we'll keep adding things
    # to it below.
    stack_size = frame.f_valuestack - frame.f_localsplus

    # If we're called from inside an exception handler, there are 3 items on the
    # stack corresponding to the exception triplet. Add 3 for every exception
    # handling block that encompasses us.
    for bi in range(frame.f_iblock):
        if frame.f_blockstack[bi].b_type == EXCEPT_HANDLER:
            stack_size += 3

    # Disassemble the current call instruction.
    bytecode_instructions = list(
            dis.Bytecode(<object> frame.f_code, current_offset=frame.f_lasti)
            )
    call_instr = bytecode_instructions[frame.f_lasti // 2]

    # Add one stack element for every for-loop surrounding the call site. Each
    # for-loop pushes an iterator onto the stack.
    stack_size += loop_nesting_level(bytecode_instructions, frame.f_lasti // 2)

    # Each flavor of the CALL instruction requires a different number of arguments.
    if call_instr.opname == 'CALL_FUNCTION':
        # +1 for the address of the function being called, +n arguments
        stack_size += 1 + call_instr.arg
    elif call_instr.opname == 'CALL_METHOD':
        # +1 for the address of the method, +1 for the object, +n arguments
        stack_size += 2 + call_instr.arg
    elif call_instr.opname == 'CALL_FUNCTION_KW':
        # +1 for the address of the function, +1 for the tuple containing
        # the names of variables, +n for the length of the tuple
        stack_size += 2 + call_instr.arg
        assert len(<object> frame.f_localsplus[stack_size - 1]) == call_instr.arg
    elif call_instr.opname == 'CALL_FUNCTION_EX':
        # +1 for the function, +1 for *args, optionally +1 for **kwargs
        stack_size += 2 + (call_instr.arg & 0x1)
    elif call_instr.opname:
        raise NotImplementedError("Don't know how to checkpoint around opcode"
                f" {call_instr.opname}. Here is the function:\n"
                + dis.Bytecode(<object> frame.f_code).dis())

    # Save a copy of the stack using the above guess. Convert NULL pointers to
    # a Python object sentinel value.
    stack_content = [
            <object>frame.f_localsplus[i] if frame.f_localsplus[i] else NULLObject
            for i in range(stack_size)
        ]

    try_block_stack = [
            frame.f_blockstack[i] for i in range(frame.f_iblock)
            ]

    saved_frame = SavedStackFrame(
            <object> frame.f_lasti,
            stack_content,
            <object> frame.f_code.co_code,
            try_block_stack,
            )

    return saved_frame


def save_jump() -> List[SavedStackFrame]:
    """Snapshot of the stack frame leading to this call.

    The ephemeral state of the stack frames between the caller and the topmost
    stack frame are copied to a list and returned. The list can be saved as a
    global, pickled, unpickled, etc. You can restore the call stack by calling
    jump() on the returned object.

    When this function returns, it can return two things:
       1. The saved state of the stack so that you can jump back to this point
       2. The empty list if you've jumped back to this point.
    """
    saved_stack: List[SavedStackFrame] = []

    if PyThreadState_Get().interp.eval_frame == <_PyFrameEvalFunction*>pyeval_fast_forward:
        PyThreadState_Get().interp.eval_frame = _PyEval_EvalFrameDefault
        log.debug('save_jump In the middle of a resume. Not saving.')
        return []

    cdef PyFrameObject *frame = PyEval_GetFrame()
    while frame:
        saved_stack.append(snapshot_frame(frame))
        frame = frame.f_back

    return saved_stack


cdef object restore_frame(PyFrameObject *frame, saved_frame: SavedStackFrame):
    """Restore the ephemeral state of a frame from the saved state.

    Copies the frame's instruction pointer and stack content from saved_frame
    to the frame object.
    """
    frame_obj = <object> frame

    log.debug('Restoring frame %s', frame_obj.f_code)

    if frame_obj.f_code.co_code != saved_frame.co_code:
        raise RuntimeError('Trying to restore frame from wrong snapshot:'
                f'\n   called_on.f_code.co_code: {frame_obj.f_code.co_code}'
                f'\n   saved_code: {saved_frame.co_code}')

    # Fast forward the instruction pointer. f_lasti points to a CALL
    # instruction (a CALL_METHOD or CALL_FUNCTION or similar). The frame
    # evaluator starts executing at f_lasti+2, but in this case, we want it to
    # re-execute the call instruction to force it to recurse on itself. So
    # preemptively decrement f_lasti by 2.
    frame.f_lasti = saved_frame.f_lasti - 2

    # Restore the content of the stack.
    cdef int i = 0
    for o in saved_frame.stack_content:
        if o == NULLObject:
            # Translate the sentinel value back to NULL.
            frame.f_localsplus[i] = NULL
        else:
            frame.f_localsplus[i] = <PyObject*> o
            Py_INCREF(o)
        i += 1

    frame.f_stacktop = frame.f_localsplus + i

    # Restore the try blocks
    frame.f_iblock = len(saved_frame.try_block_stack)
    for i in range(frame.f_iblock):
        frame.f_blockstack[i] = saved_frame.try_block_stack[i]

jump_stack = []


cdef object pyeval_fast_forward(PyFrameObject *frame, int exc):
    global jump_stack

    # Temporarily disable calling ourselves while we restore the frame. This
    # lets us call Python functions in restore_frame()
    PyThreadState_Get().interp.eval_frame = _PyEval_EvalFrameDefault
    restore_frame(frame, jump_stack.pop())

    PyThreadState_Get().interp.eval_frame = <_PyFrameEvalFunction*> pyeval_fast_forward

    r = _PyEval_EvalFrameDefault(frame, exc)
    log.debug('finished evaluating %s', <object> frame.f_code)


def jump(saved_frames: List[SavedStackFrame]):
    """Restore the state of the call stack.

    `saved_frames` is an object returned by save_jump().

    Restores the Python stack frames, the content of the stack frames, and the
    state of the CPython's internal call stack (the "C stack").

    The program proceeds from where saved_frames was generated and continues
    until the outermost function in the call stack returns. The return value
    of jump() is the return value of that outerframe.
    """
    global jump_stack
    jump_stack.clear()
    jump_stack.extend(list(saved_frames))

    cdef PyFrameObject *top_frame = PyEval_GetFrame()
    while top_frame.f_back:
        top_frame = top_frame.f_back

    log.debug('top frame for resume: %s', <object>top_frame.f_code)
    PyThreadState_Get().interp.eval_frame = <_PyFrameEvalFunction*>pyeval_fast_forward

    return pyeval_fast_forward(top_frame, 0)
