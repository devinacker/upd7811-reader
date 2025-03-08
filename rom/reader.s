; -----------------------------------------------------------------------------
; NEC 87AD reader source for external ROM
; Written for the Macro Assembler AS (http://john.ccac.rwth-aachen.de:8000/as/).
; Burn this to a 27C256 EPROM or compatible (AT29C256, W27E257, etc)
;
; The reader PCB is wired up to initially boot from this external ROM, which is
; mapped to both the 0000-7FFF and 8000-FFFF areas by leaving A15 unused.
; This does two things:
; - allows always running from external ROM even after enabling up to 32kb of internal ROM
; - allows comparing the upper and lower halves of memory to detect the internal ROM size
;
; After booting and then jumping to the ROM mirror at 8000+, MODE0 is pulled low via PC7,
; which immediately enables internal ROM. The size is detected, and then the contents are
; output in Intel HEX format over serial (115200 baud, 8N1).
; -----------------------------------------------------------------------------

	cpu 7810
	
PORT_C_TXD   equ 001h
PORT_C_LED   equ 020h
; NOTE: if modifying this code, take care to never directly drive these high
; (see comment in Port_Init)
PORT_C_MODE1 equ 040h ; not really used, just reusing the pullup on PC6
PORT_C_MODE0 equ 080h ; bring low to enable internal ROM

; -----------------------------------------------------------------------------
; internal RAM
; -----------------------------------------------------------------------------	
	org 0ff00h
PortCMode: db ?

; -----------------------------------------------------------------------------	
; external ROM (32kb mirrored at 0000-7fff and 8000-feff)
; -----------------------------------------------------------------------------
	org 08000h
	assume v:0ffh
	
	di
	jre   Start
	
	; dummy interrupt handlers
	org 08004h
	reti
	org 08008h
	reti
	org 08010h
	reti
	org 08018h
	reti
	org 08020h
	reti
	org 08028h
	reti
	org 08030h
	db "External ROM for 87AD reader (v1.0)"
	org 08060h
	reti
	
Start:
	; enable internal RAM and full external bus
	mvi   a, 0fh
	mov   mm, a
	; jump to ROM mirror at $8000+
	jmp +
+	
	; point stack and direct page at internal RAM
	mvi   v,  0ffh
	lxi   sp, 0
	; init internal RAM
	lxi   ea, 0
	lxi   hl, 0ff00h
	mvi   c,  07fh
-	steax (hl++)
	dcr   c
	jr    -
	
	; init serial before port C, per manual
	call  Serial_Init
	call  Port_Init
	call  Serial_Enable

;	call  Serial_WriteText
;	db    "INIT OK\n",0

	; pull MODE0 low to enable internal ROM
	call  PortC_EnableIntROM
	; check for external ROM mirroring to determine internal ROM size
	; (returns size in EA)
	call  DetectROMSize
	
	lxi   hl, 0
.loop:
	dne   ea, hl
	j     .end
	
	; write 16-byte record
	mvi   a, 0
	mvi   c, 16
	call  Serial_WriteHexRecord
	sbi   c, 1
-	ldax  (hl+)
	call  Serial_WriteHexByte
	dcr   c
	jr    -
	
	; blink the LED every 256 bytes as an activity indicator
	nei   l, 0
	call  PortC_ToggleLED
	
	call  Serial_WriteHexRecordEnd
	jr    .loop
	
.end:
	; write end record and quit
	mvi   a, 1
	mvi   c, 0
;	lxi   hl, 0
	call  Serial_WriteHexRecord

	call  PortC_EnableLED

-	hlt
	jr    -

DetectROMSize:
	lxi   ea, 0
	; detect 4k ROM
	lxi   hl, TestEnd4k
	call  CheckMirror
	ret
	lxi   ea, 01000h
	; detect 8k ROM
	lxi   hl, TestEnd8k
	call  CheckMirror
	ret
	lxi   ea, 02000h
	; detect 16k ROM
	lxi   hl, TestEnd16k
	call  CheckMirror
	ret
	lxi   ea, 04000h
	; detect 32k ROM
	lxi   hl, TestEnd32k
	call  CheckMirror
	ret
	lxi   ea, 08000h
	ret

CheckMirror:
	; compare potentially mirrored areas in $0000-7fff and $8000-ffff
	push  hl
	pop   de
	ani   d, 07fh
	mvi   c, 01fh
-
	ldax  (de+)
	mov   b, a
	ldax  (hl+)
	; if the two areas don't match, return with skip and check the next candidate
	eqa   b, a
	rets
	; otherwise continue
	dcr   c
	jr    -
	ret

; -----------------------------------------------------------------------------
; I/O port routines
; -----------------------------------------------------------------------------

Port_Init:
	; init ports
	mvi   a,  0ffh
	mov   ma, a
	mov   mb, a
	; output on port C for serial, leave everything else as input.
	; because MODE0/1 also double as open collector outputs, we only want
	; to set the connected port pins as outputs when driving them low.
	; the rest of the time, set them as inputs and use the external pullups.
	mvi   a,   PORT_C_TXD
	mov   pc,  a ; set serial out high, all other bits low
	mov   mcc, a ; enable TXD bit, set others to generic I/O
	xri   a,   0ffh ; set all generic I/O pins as inputs at first
	j     PortC_Init

; -----------------------------------------------------------------------------
PortC_DisableIntROM:
	mvi   a, PORT_C_MODE0
	; fall through
PortC_DisableLED:
	mvi   a, PORT_C_LED
	; fall through
PortC_Set:
	oraw  PortCMode
	jr    PortC_Init

; -----------------------------------------------------------------------------
PortC_EnableIntROM:
	mvi   a, PORT_C_MODE0
	; fall through
PortC_EnableLED:
	mvi   a, PORT_C_LED
	; fall through
PortC_Clear:
	xri   a, 0ffh
	anaw  PortCMode
	jr    PortC_Init
	
; -----------------------------------------------------------------------------
PortC_ToggleLED:
	mvi   a, PORT_C_LED
	; fall through
PortC_Toggle:
	xraw  PortCMode
	jr    PortC_Init

; -----------------------------------------------------------------------------
PortC_Init:
	staw  PortCMode
	mov   mc, a
	ret


; -----------------------------------------------------------------------------
; Serial routines
; -----------------------------------------------------------------------------

Serial_Init:
	;           ,,,------ disable timer1
	;           |||,----- disable timer0 (for now)
	;           ||||,,--- clock/12
	;           ||||||,,- output timer0
	mvi   tmm, 010010000b
	mvi   a,   4 ; clock/(12*2*4) = 115200 baud
	mov   tm0, a
	;           ,-------- unused
	;           |,------- disable SCK
	;           ||,------ disable interface mode
	;           |||,----- disable search mode
	;           ||||,---- disable Rx
	;           |||||,--- disable Tx (for now)
	;           ||||||,,- use timer output
	mvi   smh, 000000000b
	;           ,,------- 1 stop bit
	;           ||,,----- no parity
	;           ||||,,--- 8 data bits
	;           ||||||,,- async, x1 prescale
	mvi   a,   001001101b
	mov   sml, a
	ret
	
; -----------------------------------------------------------------------------
Serial_Enable:
	;                ,--- enable Tx
	ori   smh, 000000100b
	;              ,----- enable timer0
	ani   tmm, 011101111b
	; unmask serial tx irq, mask others
	mvi   a,   011111111b
	mov   mkl, a
	mvi   a,   011111011b
	mov   mkh, a
	; clear tx irq if necessary
	skit  fst
	nop
	ret

; -----------------------------------------------------------------------------
Serial_WriteHexByte:
	sub   b, a ; update checksum
	; fall through
Serial_WriteNibbles:
	push  v
	slr   a
	slr   a
	slr   a
	slr   a
	call  Serial_WriteNibble
	pop   v
	ani   a, 0fh
	; fall through
Serial_WriteNibble:
	lti   a, 0ah
	adi   a, 07h
	adi   a, '0'
	; fall through
Serial_WriteByte:
	mov   txb, a
-	hlt
	skit  fst
	jr    -
	ret

; -----------------------------------------------------------------------------
Serial_WriteHexRecord:
	; A = record type
	; B = checksum
	; C = byte count
	; HL = address
	mvi   b, 0 ; reset checksum
	push  v
	mvi   a, ':'
	call  Serial_WriteByte
	mov   a, c
	call  Serial_WriteHexByte
	mov   a, h
	call  Serial_WriteHexByte
	mov   a, l
	call  Serial_WriteHexByte
	pop   v
	call  Serial_WriteHexByte
	; if byte count is nonzero, exit now
	eqi   c, 0
	ret
	; otherwise, write the end of the record now
Serial_WriteHexRecordEnd:
	; B = checksum
	mov   a, b
	call  Serial_WriteNibbles
	mvi   a, '\n'
	j     Serial_WriteByte

; -----------------------------------------------------------------------------
Serial_WriteText:
	exx
	pop   hl
-
	ldax  (hl+)
	nei   a, 0
	jr    +
	call  Serial_WriteByte
	jr    -
+
	push  hl
	exx
	ret

; -----------------------------------------------------------------------------
; misc. data (and filler)
; -----------------------------------------------------------------------------

	; cheesy way to detect mirroring (or missing internal ROM) when using a 32kb ROM
	org 08fe0h
TestEnd4k:
	db "87AD reader test"
	db "-end of 4kb ROM-"
	org 09fe0h
TestEnd8k:
	db "87AD reader test"
	db "-end of 8kb ROM-"
	org 0bfe0h
TestEnd16k:
	db "87AD reader test"
	db "-end of 16k ROM-"
	org 0fee0h
TestEnd32k:
	db "87AD reader test"
	db "-end of 32k ROM-"
	
	; pad to 32kb
	org 0ffffh
	db 0ffh
	