# tms9900_assembler

Many years ago (in 2013) I got a box full of Texas Instruments 9900 stuff,
much of it in non-working condition. I managed to get it up and running 
again (quite a fun story: http://www.vaxman.de/projects/tms9900_100/index.html)
and then needed some way to cross-develop programs for this particular 16 bit
system.

Since I prefer developing software on a decent UNIX system and then cross
compiling/assemling it to a historic target system, I needed at least a basic
TMS9900 assembler which is contained in this project (reading my comments in 
the source it seems that this project took only about 20 hours of programming
time :-) ).

The assembler does not require any exotic Perl modules and thus should run fine
on basically every Perl installation. 

A typical input file looks like this:
```
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
```

The assembler expects the filename of the source file as a command line parameter and 
accepts three optional parameters:

1) -im: Generate an IM output suitable to be loaded into the TMS9900 system. This should be
    the default operation and thus, -im should always be specified.
2) -list: Generate a listing file which looks like this in the case of the above example:
3) -verbose: Tell which actions are performed during an assembler run.

A typical command line looks like this:
```
perl as9900.pl -im -list example.asm
```
It generates the following output:
```
                                     .org  $fc00               
                    no_of_pattern    .equ  $8                  
FC00 0201 0008                       li    r1, no_of_pattern   ; Number of patterns
FC04 0203 EFFE                       li    r3, $effe           ; End address
FC08 0641           p_loop           dect  r1                  ; Process next pattern
FC0A C021 FC3A                       mov   @pattern(r1), r0    ; Load pattern
FC0E 2FA0 FC42                       xop   @p_text, 14         
FC12 2E80                            xop   r0, 10              ; Print pattern
FC14 2FA0 FC52                       xop   f_text, 14          
FC18 0202 B000                       li    r2, $b000           ; Start address
FC1C 80C2           loop             c     r2, r3              ; End reached?
FC1E 1309                            jeq   next                ; Yes
FC20 C480                            mov   r0, *r2             ; Write pattern to memory
FC22 C112                            mov   *r2, r4             ; Read the pattern back
FC24 8004                            c     r4, r0              ; Compare patterns
FC26 1303                            jeq   l_1                 ; OK, write next memory cell
FC28 2E82                            xop   r2, 10              
FC2A 2FA0 FC68                       xop   @blank, 14          
FC2E 05C2           l_1              inct  r2                  
FC30 10F5                            jmp   loop                ; Write next word
FC32 C000           next             mov   r0, r0              ; End reached?
FC34 16E9                            jne   p_loop              ; Start writing next pattern
FC36 0420 FFFC      exit             blwp  @$fffc              ; Return to monitor
                                                               
FC3A 0000 5555 AAAA 
     FFFF           pattern          .data $0000, $5555, $aaaa, $ffff
                                                               
                                                               
FC42 0D0A 5445 5354 
     5041 5454 4552 
     4E3A 2000      p_text           .text "\nTESTPATTERN: "   
                                                               
                                                               
                                                               
FC52 0D0A 4641 554C 
     5459 2041 4444 
     5245 5353 4553 
     3A20 0000      f_text           .text "\nFAULTY ADDRESSES: "
FC68 2000           blank            .text " "                 
                                                               
-------------------------------------------------------------------------------
10 labels, sorted by name:
blank            : FC68    exit             : FC36    f_text           : FC52    
l_1              : FC2E    loop             : FC1C    next             : FC32    
no_of_pattern    : 0008    p_loop           : FC08    p_text           : FC42    
pattern          : FC3A    
-------------------------------------------------------------------------------
10 labels, sorted by address:
no_of_pattern    : 0008    p_loop           : FC08    loop             : FC1C    
l_1              : FC2E    next             : FC32    exit             : FC36    
pattern          : FC3A    p_text           : FC42    f_text           : FC52    
blank            : FC68    
-------------------------------------------------------------------------------
Paste this:

IM FC00 0201 0008 0203 EFFE 0641 C021 FC3A 2FA0 FC42 2E80 2FA0 FC52 0202 B000 80C2 1309 C480 C112 8004 1303 2E82 2FA0 FC68 05C2 10F5 C000 16E9 0420 FFFC 0000 5555 AAAA FFFF 0D0A 5445 5354 5041 5454 4552 4E3A 2000 0D0A 4641 554C 5459 2041 4444 5245 5353 4553 3A20 0000 2000 
IR  FC00 
EX 
```

