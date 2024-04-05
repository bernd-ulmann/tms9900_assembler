                 .org  $fc00               
no_of_pattern    .equ  $8                  
                 li    r1, no_of_pattern   ; Number of patterns
                 li    r3, $effe           ; End address
p_loop           dect  r1                  ; Process next pattern
                 mov   @pattern(r1), r0    ; Load pattern
                 xop   @p_text, 14         
                 xop   r0, 10              ; Print pattern
                 xop   f_text, 14          
                 li    r2, $b000           ; Start address
loop             c     r2, r3              ; End reached?
                 jeq   next                ; Yes
                 mov   r0, *r2             ; Write pattern to memory
                 mov   *r2, r4             ; Read the pattern back
                 c     r4, r0              ; Compare patterns
                 jeq   l_1                 ; OK, write next memory cell
                 xop   r2, 10              
                 xop   @blank, 14          
l_1              inct  r2                  
                 jmp   loop                ; Write next word
next             mov   r0, r0              ; End reached?
                 jne   p_loop              ; Start writing next pattern
exit             blwp  @$fffc              ; Return to monitor

pattern          .data $0000, $5555, $aaaa, $ffff


p_text           .text "\nTESTPATTERN: "   



f_text           .text "\nFAULTY ADDRESSES: "
blank            .text " "                 

