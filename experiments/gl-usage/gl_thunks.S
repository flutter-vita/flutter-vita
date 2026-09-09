@ One counting thunk per GL entry point Skia binds.
@
@ Skia does not call vitaGL by symbol. It asks VitaGlProcResolver for a name
@ and stores the pointer, so a link map cannot say what an app uses: vitaGL's
@ vglGetProcAddress holds a name table that references every entry point it
@ has, and --gc-sections therefore keeps all 372 of them, glBegin and gluLookAt
@ included. The only way to count what an app calls is to count the calls.
@
@ gl_usage.c hands out gl_thunks + i*64 in place of the real pointer. Each
@ thunk works out its own index from its own address, so all 384 copies are the
@ same 16 instructions and .rept can emit them.
@
@ What a thunk must not disturb: r0-r3 and the VFP registers carry the
@ arguments, and lr carries the return, so the callee returns straight to Skia.
@ Only r12 is free by the ARM procedure call standard, and one register is not
@ enough to increment a counter, so r0-r2 are saved and restored before the
@ branch. Nothing is called in between, so the misaligned stack in the middle
@ reaches nobody.
	.arch armv7-a
	.arm
	.section .text.gl_thunks,"ax",%progbits
	.global gl_thunks
	.type gl_thunks, %function
	.align 6
gl_thunks:
	.rept 384
	push	{r0, r1, r2}
	@ pc reads as this instruction + 8, so this is the address of the push.
	sub	r0, pc, #12
	movw	r1, #:lower16:gl_thunks
	movt	r1, #:upper16:gl_thunks
	sub	r0, r0, r1
	lsr	r0, r0, #6		@ 64 bytes per thunk
	movw	r1, #:lower16:gl_counters
	movt	r1, #:upper16:gl_counters
	ldr	r2, [r1, r0, lsl #2]
	add	r2, r2, #1
	str	r2, [r1, r0, lsl #2]
	movw	r1, #:lower16:gl_targets
	movt	r1, #:upper16:gl_targets
	ldr	r12, [r1, r0, lsl #2]
	pop	{r0, r1, r2}
	bx	r12
	.endr
	.size	gl_thunks, .-gl_thunks
	.section .note.GNU-stack,"",%progbits
