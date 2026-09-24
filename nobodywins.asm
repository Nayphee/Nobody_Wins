; ==============================================================
; NOBODY WINS
;   pal/ntsc detection, a real 50hz game tick on either machine,
;   a 26x25 arena (26 wide so the base sits on a true centre
;   line - battle city's own field is a similar 26x26-cell grid)
;   loaded from level data in the same 0-6 byte format the level
;   editor exports, drawn into the left 26 columns of the screen
;   with cols 26-39 reserved as a status sidebar. the base's
;   position is fixed by convention (rows 21-22, cols 12-13 of
;   the level data) - the editor won't let you move it, same as
;   the original never varying it between stages.
;
;   new this stage: both tanks move on joystick input, grid-
;   snapped on their perpendicular axis so wall collision stays
;   exact; blocked by steel/brick/base, the field edge, and each
;   other. the level's tile types now live in a writable `field`
;   buffer separate from the on-screen template (`level1`), so a
;   later stage can turn a brick cell to floor without touching
;   the source data. still no bullets/enemies.
;
;   note: player 1 reads joystick port 1 ($dc01), which shares
;   its data lines with the keyboard matrix - holding certain
;   keys while playing can register as phantom directions. the
;   kernal's own irq housekeeping (keyboard scan, clock) keeps
;   running every tick via the jmp $ea31 in irq below.
; ==============================================================

*=$0801
        byte $0b,$08,$0a,$00,$9e,$32,$30,$36,$31,$00,$00,$00
*=$080d

; ---- zero page pointers (ours: $fb-$fe, $f7-$fa) -----------
scrptr  = $fb           ; screen ram pointer, 2 bytes
colptr  = $fd           ; colour ram pointer, 2 bytes
lvlptr  = $f7           ; level/field data pointer, 2 bytes (rs-232 zp, free here)
dstptr  = $f9           ; second pointer, used only during the field copy

; ---- hardware ------------------------------------------------
d011    = $d011
d012    = $d012
d015    = $d015
muxvec  = $f5           ; indirect jump for the multiplexer dispatch
d01b    = $d01b         ; sprite-to-background priority
d01c    = $d01c
d027    = $d027
ciicr   = $dc0d
irqvec  = $0314
joy1    = $dc01
joy2    = $dc00

maxenemyspawn = 4
enemiesperstage = 20    ; tanks per stage, only 4 on the field at once
spawndelay = 50         ; ticks between arrivals (~1s at 50hz)
fieldbytes = 650        ; 26*25
topline = 50            ; first visible sprite line - top of the field
zoneline1 = 117         ; field (y=50..250, 200px) split into thirds
zoneline2 = 184
blktop  = 3             ; the block grid starts here; rows 0-2 are
                         ; the entry band
duelbaserow = 0          ; player 2's base in a duel, mirroring
baserow = 23            ; the eagle is a 2x2 block with its top-left
basecol = 12            ; here - it sits on the bottom edge of the map
tankptr = 64           ; ($5000-$4000)/64 - tank sprites, clear of the
                         ; charset block at $4800-$4fff: two tread
                         ; phases per facing, so the pointer is
                         ; tankptr + facing*2 + phase. the phase only
                         ; advances when the tank actually moves, so
                         ; the tracks are still when it is.
bulletptr = 72         ; ($5200-$4000)/64 - shell sprite block
bordercol = 0           ; the border: black
screencol = 12          ; the screen, and so the playfield floor: grey.
                        ; named, because the ending's white-out puts
                        ; them back and once put back the wrong ones
basetargetx = 128       ; its pixel centre: x (120+136)/2,
basetargety = 242       ; y (234+250)/2

start   sei
        lda #bordercol       ; border (the c64's other main screen
        sta $d020             ; colour, alongside background) - black
        lda #screencol        ; background - grey. the kernal's power-
        sta $d021              ; on default is blue on light blue; the
                                ; whole playfield's floor colour comes
                                ; from this register (floor cells are
                                ; just blank space - see decodetile)
        lda $dd02             ; vic bank 1: $4000-$7fff. bank 0 had to
        ora #%00000011        ; hold code, data, the charset AND the
        sta $dd02              ; sprites, and the code finally grew into
        lda $dd00              ; the charset - which was writing glyphs
        and #%11111100        ; straight through the field buffer.
        ora #%00000010        ; the bits are inverted: %10 = bank 1
        sta $dd00
        jsr initchars
        jsr detectstd
        jsr settimer
        lda $dc04            ; seed the enemy-ai rng from the free-
        eor $dc05            ; running cia timers (micropong's trick -
        eor $dd04            ; see maths.md - as random as the c64 gets
        adc $dd05            ; at power-on)
        eor $dd06
        eor $dd07
        bne @seedok
        lda #1               ; 0 is rand256's one fixed point - avoid it
@seedok sta seed
        jsr initsound
        jsr entertitle
        lda #<irq
        sta irqvec
        lda #>irq
        sta irqvec+1
        lda #$81
        sta ciicr        ; enable cia1 timer a irq (keeps kernal's own use of it too)
        lda $d01a
        ora #%00000001   ; also enable the vic raster irq, for the
        sta $d01a        ; enemy-sprite multiplexer (muxirq below) -
        lda #topline     ; this runs alongside, not instead of, the
        sta $d012        ; cia timer irq above; the shared handler
        lda $d011        ; below tells the two apart via $d019/$dc0d
        and #$7f
        sta $d011
        jsr initmux
        cli

; ------------------------------------------------------------
; main loop: title screen -> play -> game over -> title. the
;            first two branches (intitle, gameover) each own a
;            whole tick when active; play only runs when
;            neither is set.
; ------------------------------------------------------------
main    lda tick
@w      cmp tick
        beq @w
        lda sidebardirty      ; the sidebar is redrawn at most once a
        beq @sbok             ; frame: a kill and a pickup in the same
        jsr drawsidebar       ; tick used to draw it two or three times
        lda #0                ; (900 instructions each), the game's
        sta sidebardirty      ; worst frame spike
@sbok   lda inattract
        bne @isattract
        lda intitle
        bne @istitle
        lda gameover
        bne @isover
        lda wavewait          ; between stages the field is frozen while
        beq @playing          ; the wave banner is up
        jsr updatewave
        jmp main
@playing
        lda endgame           ; the last stage has been won and the
        beq @noend            ; missile is on its way
        jsr updateending
        lda gameover          ; and if it has just landed, that is the end
        beq @noend            ; of the tick: the rest would still run, and
        jmp main              ; a held fire button put a shot's click on
                               ; top of the explosion
@noend  jsr updateplayers
        jsr updatebullets
        jsr updateenemies
        jsr updateenemybullets
        jsr updateextras
        jsr updatedrone       ; the bonus drone, when there is one
        jsr buildsprites
        jmp main
@istitle
        jsr anthemrun
        jsr checktitle
        jmp main
@isattract
        jsr anthemrun
        jsr checkattract
        jmp main
@isover jsr checkrestart
        jmp main

; ------------------------------------------------------------
; setupgame   (re)start a round: lives, both tanks alive (or
;             just player 1, in solo mode), base intact, level
;             redrawn from level1, tanks placed at their
;             spawns, enemies spawned. called once a mode is
;             chosen on the title screen, and again on every
;             restart from game-over (back through the title
;             screen, so the mode can be changed between games).
;   uses: a
; ------------------------------------------------------------
setupgame
        lda #3                ; three lives each...
        ldx duelmode
        beq @lives
        lda #9                ; ...but nine in a duel: long enough for a
@lives  sta p1lives           ; thrashing to make the reactor tempting
        sta p2lives
        lda #0
        sta sidebardirty
        lda #0                ; no drone left over from a game that
        sta dronestate        ; ended while one was flying
        lda #1
        sta p1alive
        sta p2alive
        lda #0
        ldx #0
@clrpb  sta pbactive,x
        inx
        cpx #4
        bne @clrpb
        sta gameover
        sta gameoverdrawn
        sta p1facing
        sta p2facing
        lda duelmode          ; in a duel player 2 starts at the top of
        beq @facesset         ; the map, so it faces DOWN - towards the
        lda #1                ; fight, the mirror of player 1
        sta p2facing
        sta p2travel
@facesset
        lda #0                ; both players' scores. (only player 1's
        sta score             ; used to be cleared - a leftover from when
        sta score+1           ; the two shared one score - so player 2's
        sta score+2           ; carried over into the next game)
        sta score+3
        sta score+4
        sta score+5
        sta p1respawn         ; and nothing from the last game's final
        sta p2respawn         ; moments: a tank still blowing up when
        sta p1cool            ; the game ended started the next one
        sta p2cool            ; invisible until its old timer ran out
        sta p1slide
        sta p2slide
        sta p1pend
        sta p2pend
        lda #0
        sta gaveup
        sta winner
        sta endgame
        sta nobodywins
        sta wreckshown
        jsr anthemstop        ; no music during play
        lda #d016norm         ; the title left row 24 scrolled on its
        sta $d016             ; last frame - put the screen back first
        lda #0
        sta scrphase
        lda startstage        ; whichever stage the menu is showing
        sta wave
        jsr buildspawnlist
        lda #40
        sta basemovetimer
        lda #80
        sta basefiretimer
        ldx startstage        ; a game started from a later stage plays
        dex                   ; at that stage's cadence, not wave 1's:
        beq @ramped           ; ramp once per wave already 'cleared'
@rampl  jsr rampdifficulty
        dex
        bne @rampl
@ramped jsr readlevel
        jsr resetextras
        lda #0                ; a new game starts unupgraded
        sta p1star
        sta p2star
        jsr initplayers
        lda nplayers
        cmp #2
        beq @p2in
        lda #0               ; solo mode: player 2 never existed
        sta p2alive
        lda d015
        and #%11111101       ; hide sprite 1
        sta d015
@p2in   jsr spawnenemies
        lda p1x
        sta p1spawnx
        lda p1y
        sta p1spawny
        lda p2x
        sta p2spawnx
        lda p2y
        sta p2spawny
        jsr drawsidebar
        jsr startwavebanner   ; wave 1 gets the same announcement as
        rts                    ; every other wave - the game used to
                                ; drop straight into play the moment the
                                ; menu was dismissed, with no beat to
                                ; find your tank before the first
                                ; arrivals

; ------------------------------------------------------------
; flashwreck   pulse the rubble red/grey while the game-over
;              screen is up. losing the base and losing your last
;              tank both end the game the same way, and the player
;              needs to see WHICH - the wreck is the only thing
;              that says the base went. only the colour ram is
;              touched, four bytes, so this is nearly free.
;   uses: a
; ------------------------------------------------------------
flashwreck
        lda wreckshown        ; a wreck exists at all? testing basealive
        bne @gone             ; missed the duel case entirely - the top
        rts                   ; base can go while the bottom one stands
@gone   lda tick
        and #8
        beq @grey
        lda #2                ; red
        jmp @put
@grey   lda #11               ; dark grey
@put    sta flashcol          ; colour ram for whichever base died.
        ldx wreckrow          ; screenrowlo/hi hold row*40, so they work
        lda #<$d800           ; for colour ram as well as the screen
        clc
        adc screenrowlo,x
        sta colptr
        lda #>$d800
        adc screenrowhi,x
        sta colptr+1
        lda flashcol
        ldy #basecol
        sta (colptr),y
        iny
        sta (colptr),y
        ldy #basecol+40       ; the row below
        sta (colptr),y
        iny
        sta (colptr),y
        rts

; ------------------------------------------------------------
; checkrestart   draw the game-over message once, then wait for
;                either fire button before returning to the
;                title screen (not straight back into a new
;                round - the whole point of going via the title
;                is that the mode can be changed between games).
;   uses: a
; ------------------------------------------------------------
checkrestart
        lda #$ff              ; defensive - see updateplayers' note
        sta $dc00
        lda gameoverdrawn
        bne @polled
        jsr drawgameover
        jsr checkhiscore
        lda #1
        sta gameoverdrawn
        lda #0                ; the fire button was almost certainly held
        sta gorelease         ; at the moment the last tank died - that
                               ; same press must not dismiss the screen
                               ; before the player has read it
        lda #gopause          ; and waiting for a release is not enough
        sta gowait            ; on its own: a player mashing the button
                               ; (no music here: it is for the title and
                               ; the briefing only) hold the screen
                               ; for a fixed spell no matter what the
                               ; stick is doing.
@polled lda nobodywins        ; the ending: no wreck to flash, no button.
        beq @notending        ; it holds a minute, then goes to the title
        lda endwait
        ora endwait+1
        beq @endover
        lda endwait
        bne @lo
        dec endwait+1
@lo     dec endwait
        rts
@endover
        lda #bordercol        ; the border and screen as start-up set
        sta $d020             ; them - the screen is grey, not black,
        lda #screencol        ; and it is also the playfield's floor
        sta $d021
        jsr entertitle
        rts
@notending
        jsr flashwreck
        lda gowait
        beq @waited
        dec gowait
        bne @stillwaiting
        lda #0                ; the pause is over - but a button held
        sta gorelease         ; through all of it still must not count
@stillwaiting
        rts
@waited lda gorelease
        bne @armed
        lda joy1              ; wait for both buttons to come up first
        and #16
        beq @wait
        lda joy2
        and #16
        beq @wait
        lda #1
        sta gorelease
@wait   rts
@armed  lda joy1              ; now a fresh press dismisses it
        and #16
        beq @restart
        lda joy2
        and #16
        beq @restart
        rts
@restart
        jsr entertitle
        rts

; ------------------------------------------------------------
; drawgameover   overlay "GAME OVER" near the centre of the field
;   uses: a, y, scrptr, colptr
; ------------------------------------------------------------
drawgameover
        lda nobodywins        ; the ending has its own last word
        beq @notend
        lda #1                ; the flash: screen and border blank white
        sta $d020
        sta $d021
        lda #0                ; nothing left standing - no sprites
        sta d015
        jsr clearscreen       ; no field, no panel, no reactor
        ldy #0
@nw     lda nobodymsg,y
        sta $4400+12*40+14,y  ; eleven characters from column 14: as near
        lda #2                ; centred on the whole screen as an odd
        sta $d800+12*40+14,y  ; length allows. red on the white
        iny
        cpy #11
        bne @nw
        lda #<endhold         ; a minute before it goes back to the title
        sta endwait
        lda #>endhold
        sta endwait+1
        rts
@notend lda #<($4400+12*40+8)
        sta scrptr
        lda #>($4400+12*40+8)
        sta scrptr+1
        lda winner            ; a duel says who survived instead:
                               ; 17 characters from column 4 - the same
                               ; centre as "NOBODY WINS" from column 7
        beq @nowin
        cmp #3                ; a reactor destroyed: nobody wins
        bne @survivor
        ldy #0
@nb     lda nobodymsg,y
        sta $4400+12*40+7,y   ; eleven characters from column 7: as near
        lda #2                ; centred on the field as an odd length
        sta $d800+12*40+7,y   ; allows. red, as at the end of the war
        iny
        cpy #11
        bne @nb
        rts
@survivor
        lda #<($4400+12*40+4)
        sta scrptr
        lda #>($4400+12*40+4)
        sta scrptr+1
        ldy #0
@wlp    lda winmsg,y
        sta (scrptr),y
        iny
        cpy #17
        bne @wlp
        lda winner            ; drop the player's number into it
        clc
        adc #48
        ldy #7
        sta (scrptr),y
        lda #<($d800+12*40+4)
        sta colptr
        lda #>($d800+12*40+4)
        sta colptr+1
        ldy #0
@wcol   lda winner            ; blue for player 1, yellow for player 2
        cmp #1
        bne @wp2
        lda #6
        jmp @wput
@wp2    lda #7                ; player 2's colour
@wput   sta (colptr),y
        iny
        cpy #17
        bne @wcol
        rts
@nowin  ldy #0
@lp     lda gaveup            ; ninety-nine stages cleared gets a
        beq @normal           ; different message
        lda giveupmsg,y
        jmp @put
@normal lda gameovermsg,y
@put    sta (scrptr),y
        iny
        cpy #10
        bne @lp
        lda #<($d800+12*40+8)
        sta colptr
        lda #>($d800+12*40+8)
        sta colptr+1
        ldy #0
@lp2    lda gaveup            ; white for the send-off, red for a loss
        beq @red
        lda #1
        jmp @putcol
@red    lda #2
@putcol sta (colptr),y
        iny
        cpy #10
        bne @lp2
        rts
gameovermsg byte 7,1,13,5,32,32,15,22,5,18   ; "GAME  OVER" - the
                          ; double space is deliberate: the playfield is
                          ; 26 wide so its centre is 12.5, and only an
                          ; even-length string can sit on it   ; "GAME OVER" screen codes
nobodymsg byte 14,15,2,15,4,25,32,23,9,14,19      ; "NOBODY WINS"
winmsg  byte 16,12,1,25,5,18,32,49,32                 ; "PLAYER n SURVIVES" - the one
        byte 19,21,18,22,9,22,5,19                    ; win there is. a reactor: nobody
                          ; fourteen characters, so it centres exactly
                          ; on the playfield; the digit is filled in
giveupmsg byte 9,32,7,9,22,5,32,21,16,33   ; "I GIVE UP!" - ten
                          ; characters, for the same reason

; ==============================================================
; STAGE 7: title screen and mode select
; ==============================================================

; ------------------------------------------------------------
; entertitle   (re)enter the title screen: draw it, reset the
;              cursor, and clear any leftover game-over state.
;   uses: a
; ------------------------------------------------------------
entertitle
        lda anon              ; carry on if the ANTHEM is already playing -
        beq @anstart          ; the briefing comes back here every lap. but
        lda anmode            ; anything else (the ditty) gives way to it
        bne @anplaying
@anstart
        jsr anthemstart
@anplaying
        lda #0
        sta d015              ; every sprite off. the briefing leaves an
                               ; enemy tank showing on sprite 0, and the
                               ; multiplexer only ever clears 2-7 - so
                               ; without this the tank stayed on the
                               ; title screen after pressing fire
        jsr showtitletanks    ; both players' tanks, under the title
        lda #1
        sta intitle
        lda #0
        sta menusel
        sta gameover
        sta gameoverdrawn
        lda joy1               ; capture whatever's actually held right
        sta joy1prev            ; now (e.g. the same fire press that
                                 ; just dismissed game over) so it can't
                                 ; immediately register as a menu press
                                 ; before the player has even seen the
                                 ; title screen or released the button
        jsr drawtitlescreen
        rts

; ------------------------------------------------------------
; checktitle   handle title-screen input: joystick 1 up/down
;              moves the cursor (edge-detected against
;              joy1prev, so holding the stick doesn't fly
;              through all 3 options in one tick); fire
;              confirms the highlighted mode and starts play.
;   uses: a
; ------------------------------------------------------------
checktitle
        lda joy1              ; any stick movement at all postpones the
        and #31               ; briefing - it should never interrupt
        cmp #31               ; someone reading the menu
        beq @quiet
        lda #attractidle
        sta attridle
@quiet  inc attrpre           ; the idle count runs on one tick in
        lda attrpre            ; eight, so a byte covers 15 seconds
        and #7                 ; instead of five
        bne @noidle
        lda attridle          ; left alone for a while? show the
        beq @noidle            ; briefing pages
        dec attridle
        bne @noidle
        jmp enterattract
@noidle
        lda #$ff              ; defensive - see updateplayers' note
        sta $dc00
        lda joy1
        and #1                 ; up
        bne @noup
        lda joy1prev
        and #1
        beq @noup
        lda menusel
        beq @upclamped
        dec menusel
@upclamped
        jsr drawtitlecursor
@noup
        lda joy1
        and #2                 ; down
        bne @nodown
        lda joy1prev
        and #2
        beq @nodown
        lda menusel
        cmp #2
        beq @downclamped
        inc menusel
@downclamped
        jsr drawtitlecursor
@nodown
        lda joy1              ; left and right choose the starting stage
        and #4
        bne @noleft
        lda joy1prev
        and #4
        beq @noleft
        lda startstage
        cmp #1
        beq @noleft
        dec startstage
        jsr drawstage
@noleft lda joy1
        and #8
        bne @noright
        lda joy1prev
        and #8
        beq @noright
        lda startstage
        cmp #35
        beq @noright
        inc startstage
        jsr drawstage
@noright
        lda joy1
        and #16                ; fire
        bne @nofire
        lda joy1prev
        and #16
        beq @nofire
        lda menusel
        cmp #0
        bne @notsolo
        lda #1
        sta nplayers
        lda #0
        sta friendlyfire
        sta duelmode
        jmp @confirmed
@notsolo
        cmp #1
        bne @notcoop
        lda #2
        sta nplayers
        lda #0
        sta friendlyfire
        sta duelmode
        jmp @confirmed
@notcoop
        lda #2
        sta nplayers
        lda #1
        sta friendlyfire
        sta duelmode          ; versus: the duel map, two bases, no AI
@confirmed
        lda #0
        sta intitle
        jsr setupgame
        rts
@nofire lda joy1
        sta joy1prev
        rts

; ------------------------------------------------------------
; drawtitlescreen   full title-screen draw: clear, title text,
;                   the 3 mode options, a hint line, cursor.
;   uses: a, y, scrptr
; ------------------------------------------------------------
drawtitlescreen
        jsr clearscreen
        lda #<($4400+3*40+10)  ; 19 characters, from column 10
        sta scrptr
        lda #>($4400+3*40+10)
        sta scrptr+1
        lda #<($d800+3*40+10)
        sta colptr
        lda #>($d800+3*40+10)
        sta colptr+1
        ldy #0
@t      lda titletext,y
        sta (scrptr),y
        cmp #pipstar          ; the stars in yellow, the name in white
        bne @tname
        lda #7
        jmp @tcol
@tname  lda #1
@tcol   sta (colptr),y
        iny
        cpy #19
        bne @t

        lda #<($4400+10*40+13)
        sta scrptr
        lda #>($4400+10*40+13)
        sta scrptr+1
        lda #<($d800+10*40+13)
        sta colptr
        lda #>($d800+10*40+13)
        sta colptr+1
        ldy #0
@o1     lda opt1text,y
        sta (scrptr),y
        lda #1
        sta (colptr),y
        iny
        cpy #8
        bne @o1

        lda #<($4400+12*40+13)
        sta scrptr
        lda #>($4400+12*40+13)
        sta scrptr+1
        lda #<($d800+12*40+13)
        sta colptr
        lda #>($d800+12*40+13)
        sta colptr+1
        ldy #0
@o2     lda opt2text,y
        sta (scrptr),y
        lda #1
        sta (colptr),y
        iny
        cpy #14
        bne @o2

        lda #<($4400+14*40+13)
        sta scrptr
        lda #>($4400+14*40+13)
        sta scrptr+1
        lda #<($d800+14*40+13)
        sta colptr
        lda #>($d800+14*40+13)
        sta colptr+1
        ldy #0
@o3     lda opt3text,y
        sta (scrptr),y
        lda #1
        sta (colptr),y
        iny
        cpy #11
        bne @o3

        lda #<($4400+21*40+10)
        sta scrptr
        lda #>($4400+21*40+10)
        sta scrptr+1
        lda #<($d800+21*40+10)
        sta colptr
        lda #>($d800+21*40+10)
        sta colptr+1
        ldy #0
@h      lda hinttext,y
        sta (scrptr),y
        lda #5                ; green
        sta (colptr),y
        iny
        cpy #20
        bne @h

        jsr drawtitlecursor
        jsr drawstage
        jsr drawhiscore
        lda #attractidle      ; the briefing comes up on its own if
        sta attridle          ; nobody touches the stick
        rts

; ------------------------------------------------------------
; drawstddiag   say which video standard was detected, on every
;               briefing page, two rows above FIRE TO RETURN.
;
;               the screen refresh differs - pal 50 hz, ntsc 60 hz -
;               but settimer programs the cia for a true 50 hz tick
;               on both, so the game itself runs at the same speed
;               either way. if detectstd ever got it wrong, the game
;               would run at a wrong but steady speed, and this line
;               is where that would show.
;
;               it used to sit on row 23 of the title screen. row 23
;               has to be empty on the title and the briefing: the
;               scroller's interrupt switches the fine scroll during
;               that row, and anything drawn there is sheared.
;   uses: a, y, scrptr, colptr
; ------------------------------------------------------------
drawstddiag
        lda #<($4400+19*40+2)
        sta scrptr
        lda #>($4400+19*40+2)
        sta scrptr+1
        lda #<($d800+19*40+2)
        sta colptr
        lda #>($d800+19*40+2)
        sta colptr+1
        ldy #0
@lp     lda videostd
        bne @pal
        lda stdntsc,y
        jmp @put
@pal    lda stdpal,y
@put    sta (scrptr),y
        lda #14               ; light blue - apart from the white text
        sta (colptr),y        ; and the green footer
        iny
        cpy #36
        bne @lp
        rts

; both 36 characters, so both centre exactly on the screen's 19.5
stdpal  byte 16,1,12,32,32,53,48,8,26,32,4,9,19,16,12,1,25,32,32,7,1,13,5,32,18,21,14,19,32,1,20,32,53,48,8,26   ; "PAL  50HZ DISPLAY  GAME RUNS AT 50HZ"
stdntsc byte 14,20,19,3,32,54,48,8,26,32,4,9,19,16,12,1,25,32,32,7,1,13,5,32,18,21,14,19,32,1,20,32,53,48,8,26   ; "NTSC 60HZ DISPLAY  GAME RUNS AT 50HZ"

; ------------------------------------------------------------
; the briefing pages
; ------------------------------------------------------------
;   a screen of its own rather than a strip squeezed under the menu:
;   there is room for the name, the picture and a line saying what
;   the thing actually does, and the enemy tanks can be shown as
;   real sprites instead of a stand-in glyph.
;
;   it comes up by itself when the title screen is left alone, and
;   fire returns to the menu at once - so it is never in the way.
; ------------------------------------------------------------
enterattract
        lda #0
        sta d015              ; the title's two tanks off. the pages turn
                               ; sprite 0 back on for theirs; nothing
                               ; there would ever have hidden sprite 1
        sta intitle
        lda #1
        sta inattract
        sta attridx
        lda #0
        sta attridx
        lda #1
        sta attrtimer
        lda #0                ; fire is probably still down from the
        sta attrarmed          ; press that got here
        jsr drawattract
        rts

; ------------------------------------------------------------
; checkattract   advance the pages, and watch for fire.
;   uses: a, x, y
; ------------------------------------------------------------
checkattract
        lda #$ff
        sta $dc00
        lda attrarmed         ; wait for fire to come up before taking
        bne @armed             ; it, so the press that arrived here
        lda joy1               ; does not bounce straight back out
        and #16
        beq @tick
        lda #1
        sta attrarmed
        jmp @tick
@armed  lda joy1
        and #16
        bne @tick
        lda #0                ; back to the menu
        sta inattract
        jsr entertitle
        rts
@tick   jsr briefdrone        ; the drone page's rotors
        dec attrtimer
        bne @done
        inc attridx
        lda attridx
        cmp #11               ; ten pages, and the drone
        bcc @redraw
        lda #0                ; shown everything - back to the menu
        sta inattract
        jsr entertitle
        rts
@redraw jsr drawattract
@done   rts

; ------------------------------------------------------------
; drawattract   one briefing page: heading, picture, name, what it
;               does, and how to leave.
;   uses: a, x, y, and everything putchar/draw2x2 use
; ------------------------------------------------------------
drawattract
        lda #attractdwell
        sta attrtimer
        jsr clearscreen
        lda #0                ; heading: tanks, items, or the drone
        sta atmp
        lda attridx
        cmp #4
        bcc @head
        ldx #12               ; heading field is 12 wide now
        cmp #10
        bcc @hitem
        ldx #24               ; the last page: the drone
@hitem  stx atmp
@head   lda #3
        sta trow
        lda #14
        sta tcol
        ldy #0
@hlp    tya
        clc
        adc atmp
        tax
        lda attrhead,x
        sta pchar
        lda #3                ; cyan
        sta pcol
        sty atmp2
        jsr putchar
        ldy atmp2
        inc tcol
        iny
        cpy #12
        bne @hlp

        lda attridx           ; picture
        cmp #4
        bcs @notank
        jsr showtanksprite    ; an enemy tank, as a real sprite
        jmp @name
@notank cmp #10
        bcc @item
        jsr showdronesprite   ; the drone, as a real sprite too
        jmp @name
@item   lda d015              ; no sprite for a bonus - it is a glyph
        and #%11111110
        sta d015
        ldx attridx
        lda attrglyph,x
        sta gbase
        lda #1                ; white, the same as on the field. yellow
        sta gcol               ; here taught the wrong thing: on the map
                                ; yellow is player 1's tank and the base,
                                ; and a pickup must not read as either
        lda #8
        sta g2row
        lda #19
        sta g2col
        jsr draw2x2

@name   lda #12               ; the name
        sta trow
        lda #14
        sta tcol
        lda attridx
        asl a
        asl a
        sta atmp              ; idx*12
        asl a
        clc
        adc atmp
        sta atmp
        ldy #0
@nlp    tya
        clc
        adc atmp
        tax
        lda attrname,x
        sta pchar
        lda #1
        sta pcol
        sty atmp2
        jsr putchar
        ldy atmp2
        inc tcol
        iny
        cpy #12
        bne @nlp

        lda #15               ; what it does
        sta trow
        lda #9                ; 22-wide field, centred on a 40 screen
        sta tcol
        lda attridx           ; idx*22
        asl a
        sta atmp              ; *2
        asl a
        asl a                 ; *8
        clc
        adc atmp              ; *10
        asl a                 ; *20
        clc
        adc atmp              ; *22
        sta atmp
        ldy #0
@elp    tya
        clc
        adc atmp
        tax
        lda attrexpl,x
        sta pchar
        lda #15
        sta pcol
        sty atmp2
        jsr putchar
        ldy atmp2
        inc tcol
        iny
        cpy #22
        bne @elp

        lda #21               ; the way out
        sta trow
        lda #13
        sta tcol
        ldy #0
@flp    lda attrfoot,y
        sta pchar
        lda #5
        sta pcol
        sty atmp2
        jsr putchar
        ldy atmp2
        inc tcol
        iny
        cpy #14
        bne @flp
        jsr drawstddiag       ; the machine's video standard, two rows up
        rts

; ------------------------------------------------------------
; showtanksprite   put enemy type attridx on screen as sprite 0,
;                  in its own colour and facing the viewer.
;   uses: a, x
; ------------------------------------------------------------
showtanksprite
        ldx attridx
        lda typecol,x
        sta d027
        lda #tankptr          ; facing up, as the players do on the title
        sta $47f8
        lda #24+19*8
        sta $d000
        lda #50+8*8+2         ; the up frame's image sits 2 higher in its
        sta $d001             ; sprite than the down frame's did: this
                               ; keeps the tank where it was, two clear
                               ; rows above its name
        lda d015
        ora #%00000001
        sta d015
        rts

; ------------------------------------------------------------
; drawstage   "STAGE nn" under the menu, adjusted with left and
;             right. without this you could only reach a stage by
;             clearing every one before it, which makes the later
;             ones impossible to look at.
;   uses: a, x, y, scrptr, colptr
; ------------------------------------------------------------
drawstage
        lda #<($4400+17*40+14)
        sta scrptr
        lda #>($4400+17*40+14)
        sta scrptr+1
        lda #<($d800+17*40+14)
        sta colptr
        lda #>($d800+17*40+14)
        sta colptr+1
        ldy #0
@lbl    lda stagelbl,y
        sta (scrptr),y
        lda #3                ; cyan, so it reads as adjustable
        sta (colptr),y
        iny
        cpy #6
        bne @lbl
        lda startstage        ; two digits
        ldx #48
@tens   cmp #10
        bcc @units
        sec
        sbc #10
        inx
        jmp @tens
@units  clc
        adc #48
        sta stgdig
        txa
        sta (scrptr),y
        lda #1
        sta (colptr),y
        iny
        lda stgdig
        sta (scrptr),y
        lda #1
        sta (colptr),y
        rts

stagelbl byte 19,20,1,7,5,32   ; "STAGE "

; ------------------------------------------------------------
; scrollertick   once a frame, on the title and the briefing.
;
;   a one-pixel smooth scroll along row 24. the fine position
;   counts 7 down to 0; when it wraps the window shifts one
;   character left and the next character of the message enters
;   at the right, where the 38-column border hides it arriving.
;
;   the window lives in scrbuf and is copied to row 24 every
;   frame, rather than scrolled in screen memory directly: both
;   screens redraw by clearing the whole screen, and a scroller
;   kept only on screen would lose everything it had shown and
;   refill from the right with a gap.
;   uses: a, x, y
; ------------------------------------------------------------
scrollertick
        dec scrfine
        bpl scrdraw
        lda #7
        sta scrfine
        ldx #0                ; shift the window left one character
@sh     lda scrbuf+1,x
        sta scrbuf,x
        inx
        cpx #39
        bne @sh
scrget  lda scrmsg            ; and feed in the next one at the right.
        cmp #$ff              ; self-modifying: this instruction's own
        bne scrgot            ; address operand walks through the
        lda #<scrmsg          ; message, a byte at a time. the message is
        sta scrget+1          ; over a thousand characters and a y index
        lda #>scrmsg          ; stops at 255. only this interrupt ever
        sta scrget+2          ; touches it, so nothing can race it.
        jmp scrget            ; end of the message: round again
scrgot  sta scrbuf+39
        inc scrget+1
        bne scrdraw
        inc scrget+2
scrdraw ldx #0
scrcopy lda scrbuf,x
        sta $4400+scrollrow*40,x
        lda #scrcol
        sta $d800+scrollrow*40,x
        inx
        cpx #40
        bne scrcopy
        rts

; ------------------------------------------------------------
; drawhiscore   "HI nnnnnn" under the menu. the high score survives
;               a game because nothing clears it - only checkhiscore
;               raises it.
;   uses: a, x, y, scrptr, colptr
; ------------------------------------------------------------
drawhiscore
        lda #<($4400+19*40+13)
        sta scrptr
        lda #>($4400+19*40+13)
        sta scrptr+1
        lda #<($d800+19*40+13)
        sta colptr
        lda #>($d800+19*40+13)
        sta colptr+1
        ldy #0
@lbl    lda hilbl,y
        sta (scrptr),y
        lda #1
        sta (colptr),y
        iny
        cpy #3
        bne @lbl
        ldx #2                ; three bcd bytes, high one first
@dig    lda hiscore,x
        pha
        lsr a
        lsr a
        lsr a
        lsr a
        clc
        adc #48
        sta (scrptr),y
        lda #7
        sta (colptr),y
        iny
        pla
        and #15
        clc
        adc #48
        sta (scrptr),y
        lda #7
        sta (colptr),y
        iny
        dex
        bpl @dig
        rts

; ------------------------------------------------------------
; marksidebar   ask for the sidebar to be redrawn at the top of
;               the next frame (see main). in-play callers use
;               this rather than drawsidebar itself.
; ------------------------------------------------------------
marksidebar
        lda #1
        sta sidebardirty
        rts

; ------------------------------------------------------------
; checkhiscore   raise the high score if this game beat it. bcd
;                compare, high byte first.
;   uses: a, x
; ------------------------------------------------------------
checkhiscore
        lda nplayers          ; in a two-player game the high score is
        cmp #2                ; whichever of them did better
        bne @use1
        lda score+5
        cmp score+2
        bcc @use1
        bne @use2
        lda score+4
        cmp score+1
        bcc @use1
        bne @use2
        lda score+3
        cmp score
        bcc @use1
@use2   lda score+3           ; copy player 2's into the compare slot
        sta hitmp
        lda score+4
        sta hitmp+1
        lda score+5
        sta hitmp+2
        jmp @cmp
@use1   lda score
        sta hitmp
        lda score+1
        sta hitmp+1
        lda score+2
        sta hitmp+2
@cmp    lda hitmp+2
        cmp hiscore+2
        bcc @no
        bne @yes
        lda hitmp+1
        cmp hiscore+1
        bcc @no
        bne @yes
        lda hitmp
        cmp hiscore
        bcc @no
@yes    lda hitmp
        sta hiscore
        lda hitmp+1
        sta hiscore+1
        lda hitmp+2
        sta hiscore+2
@no     rts

hilbl   byte 8,9,32           ; "HI "

; ------------------------------------------------------------
; drawtitlecursor   clear all 3 cursor slots, then draw the
;                   cursor mark at whichever one menusel points
;                   to. cheap enough to just do all 3 each time
;                   rather than tracking the previous position.
;   uses: a, y, scrptr, colptr
; ------------------------------------------------------------
drawtitlecursor
        ldy #0
        lda #<($4400+10*40+11)
        sta scrptr
        lda #>($4400+10*40+11)
        sta scrptr+1
        lda #32
        sta (scrptr),y
        lda #<($4400+12*40+11)
        sta scrptr
        lda #>($4400+12*40+11)
        sta scrptr+1
        lda #32
        sta (scrptr),y
        lda #<($4400+14*40+11)
        sta scrptr
        lda #>($4400+14*40+11)
        sta scrptr+1
        lda #32
        sta (scrptr),y

        lda menusel
        cmp #0
        beq @row0
        cmp #1
        beq @row1
        jmp @row2
@row0   lda #<($4400+10*40+11)
        sta scrptr
        lda #>($4400+10*40+11)
        sta scrptr+1
        lda #<($d800+10*40+11)
        sta colptr
        lda #>($d800+10*40+11)
        sta colptr+1
        jmp @draw
@row1   lda #<($4400+12*40+11)
        sta scrptr
        lda #>($4400+12*40+11)
        sta scrptr+1
        lda #<($d800+12*40+11)
        sta colptr
        lda #>($d800+12*40+11)
        sta colptr+1
        jmp @draw
@row2   lda #<($4400+14*40+11)
        sta scrptr
        lda #>($4400+14*40+11)
        sta scrptr+1
        lda #<($d800+14*40+11)
        sta colptr
        lda #>($d800+14*40+11)
        sta colptr+1
@draw   ldy #0
        lda #42            ; '*'
        sta (scrptr),y
        lda #1
        sta (colptr),y
        rts

; ------------------------------------------------------------
; clearscreen   blank the full 40x25 screen+colour ram (used
;               entering the title screen, over the game
;               that was previously drawn there).
;               was a byte-at-a-time loop using (ptr),y indirect
;               addressing plus a 16-bit pointer increment/carry
;               check on every single byte - ~34,000 cycles
;               (~1.7 ticks, ~35ms), a real, never-optimised
;               freeze right at the "dismiss game over" moment.
;               direct page-indexed addressing (x as the index,
;               the page number baked into each store) does the
;               same 2000 writes for under half the cost, since
;               there's no per-byte pointer bookkeeping at all -
;               same idea as the tileat/readlevel fixes, applied
;               to the one remaining unoptimised full-screen loop.
;   uses: a, x
; ------------------------------------------------------------
clearscreen
        ldx #0
@lp1    lda #32
        sta $4400,x
        sta $4500,x
        sta $4600,x
        lda #0
        sta $d800,x
        sta $d900,x
        sta $da00,x
        inx
        bne @lp1            ; 3 full pages (768 cells) done
        ldx #0
@lp2    cpx #232            ; the remaining 232 cells (1000-768)
        beq @done
        lda #32
        sta $4700,x
        lda #0
        sta $db00,x
        inx
        jmp @lp2
@done   rts

titletext byte pipstar,pipstar,pipstar,32
        byte 14,15,2,15,4,25,32,23,9,14,19          ; "NOBODY WINS"
        byte 32,pipstar,pipstar,pipstar
opt1text byte 49,32,16,12,1,25,5,18                     ; "1 PLAYER"
opt2text byte 50,32,16,12,1,25,5,18,32,3,15,45,15,16    ; "2 PLAYER CO-OP"
opt3text byte 50,32,16,12,1,25,5,18,32,22,19            ; "2 PLAYER VS"
hinttext byte 16,18,5,19,19,32,6,9,18,5,32,20,15,32,19,20,1,18,20,32 ; "PRESS FIRE TO START" (padded to 20)

; ------------------------------------------------------------
; irq     shared handler for two independent interrupt sources
;         funnelled into the same vector: cia1 timer a (our
;         50hz game tick) and the vic raster (the enemy-sprite
;         multiplexer's band swap). each is checked and acked
;         separately, since either or both can have fired.
;
;         the cia tick genuinely needs the kernal's own irq
;         housekeeping afterward (keyboard scan, jiffy clock) -
;         joystick 1 shares lines with the keyboard matrix, so
;         that scan has to keep running. but the raster interrupt
;         doesn't need any of that, and it fires 3x per frame
;         (150-180 times/sec) versus the cia tick's 50/sec - so a
;         plain raster-only entry (the majority of the time,
;         since the two aren't phase-locked) used to run the FULL
;         kernal housekeeping anyway, 2-3x more often than
;         necessary. that's not just wasted cycles: if any part
;         of that kernal path has an occasionally-slow case
;         (keyboard debounce, a clock rollover, whatever), running
;         it far more often than needed would show up as exactly
;         the kind of sporadic stall being reported. a raster-only
;         entry now exits via $ea81 - the kernal's own documented
;         "restore regs + rti, skip the keyboard scan" exit point -
;         instead of $ea31's full housekeeping. only a genuine cia
;         tick still goes through $ea31.
;   uses: a
; ------------------------------------------------------------
irq     cld                  ; an irq can land between addscore's
                             ; sed and cld; the chain below does
                             ; arithmetic, so clear it first
        lda $d019
        and #1
        beq @checkcia
        jsr muxirq
        asl $d019            ; ack the raster irq
@checkcia
        lda $dc0d            ; reading acks cia1's irq flags;
        and #1               ; bit0 tells us timer a was the source
        beq @fastret          ; raster-only - skip kernal housekeeping
        inc tick              ; genuine cia tick. fast exit, NOT the
        jmp $ea81             ; kernal's full $ea31: that runs the jiffy
                               ; clock, STOP key, cursor and keyboard
                               ; scan - a few thousand cycles, 25-40
                               ; raster lines - none of which the game
                               ; uses (joysticks are read from the cia
                               ; ports directly). settimer runs the cia
                               ; at a true 50 hz, but it is free-running,
                               ; not locked to the raster - on pal it is
                               ; about 48 cycles a frame slower, so it
                               ; drifts right round the frame every eight
                               ; seconds or so, and whenever it landed
                               ; just before a raster interrupt it held
                               ; that interrupt up by all of it. the
                               ; scroller's $d016 write then missed row
                               ; 24 and the row tore for a frame.
@fastret
        jmp $ea81             ; kernal's own "restore regs + rti,
                               ; skip keyboard scan" exit point -
                               ; documented in kernal-and-memory.md,
                               ; safer than hand-rolling the same
                               ; pla/tay/pla/tax/pla/rti sequence
                               ; myself and risking getting the
                               ; push order wrong from memory

; ==============================================================
; STAGE 5 (rewritten): sorted sprite multiplexer
; ==============================================================
;   sprites 0-1 stay dedicated to the two player tanks. those are
;   the one thing that must never blink, and reserving them costs
;   nothing.
;
;   sprites 2-7 - six of them - are a multiplexed pool covering
;   everything else: up to 4 enemy tanks, 4 enemy bullets and 4
;   player bullets. twelve objects on six sprites.
;
;   the player bullets used to own sprites 2 and 3 outright. that
;   capped each player at one shell, which is what blocked the
;   star's third level. folding them into the pool frees both
;   sprites and raises the pool from 4 to 6, and measurement over
;   4000 frames of play says the screen never holds more than 5
;   objects inside a 21-scanline window - so six is headroom
;   rather than a squeeze.
;
;   the hardware constraint is unchanged: a sprite cannot be
;   reused until it has finished drawing, so sorted object n -
;   which takes the sprite object n-6 had - needs its y at least
;   21 lines below that one's.
; ------------------------------------------------------------
; the playfield buffer lives in free ram high in the vic bank, not in
; the code area. it used to be 650 bytes of zeros at the end of the
; code, and as the code grew it crept to $41ec-$4476 - PAST $4400,
; into screen memory. field row 23, the base, sat on screen row 1
; column 26, exactly where the sidebar draws SCORE: each updated the
; other. nothing needs it pre-cleared; readlevel and readduel fill it.
field   = $7800            ; moved up from $6000 to make room for
                          ; the scroller's message, which follows the
                          ; character shapes
muxtop  = 44              ; frame-top irq, above the field
missiletop = 22           ; the missile starts in the top border, out of
                          ; sight, and slides down into view
missilehit = 214          ; its nose (21 rows down) meets the reactor's
                          ; top edge at y 234
launchdelay = 250         ; fifteen seconds of siren before it appears:
                          ; endtimer counts in threes while it waits (a
                          ; byte cannot reach 750), so 250 of them
sirlo   = 2400            ; the siren's sweep
sirhi   = 7200
sirstep = 48              ; 100 ticks, two seconds, each way
icbmptr = ($5d40-$4000)/64
scrollrow = 24            ; the scroller's row, title and briefing only
scrline = 235             ; its interrupt: early in row 23 (234-241),
                          ; which must stay blank on both screens -
                          ; the video standard used to be shown there
                          ; and was sheared by this. so the
                          ; $d016 write can land anywhere in that row
                          ; unseen. at 240 it had 1.1 lines of margin
                          ; before row 24 began, and any delay beyond
                          ; about 70 cycles tore the row
d016norm = $c8            ; 40 columns, no fine scroll
d016title = $c0           ; 38 columns, no fine scroll: title and briefing
d016scroll = $c0          ; 38 columns; the fine scroll is or-ed in
scrcol  = 1               ; white
muxpool = 6               ; hardware sprites 2..7
muxobjs = 12              ; 4 enemy tanks, 4 enemy bullets, 4 player

; ------------------------------------------------------------
; buildsprites   once per tick: apply the draw-offset correction,
;                sort the objects by y, and build the display
;                list into the inactive bank, then flip.
;   uses: a, x, y, and the obj*/dsp* arrays
; ------------------------------------------------------------
buildsprites
        ldx #0
@glp    lda moactive,x
        bne @live
        lda #255              ; inactive sinks to the end of the sort
        sta objy,x
        jmp @gnext
@live   cpx #4
        bcs @isbul
        ldy modir,x           ; enemy tank
        lda mox,x
        sec
        sbc dirdx,y
        sta objx,x
        lda moy,x
        sec
        sbc dirdy,y
        sta objy,x
        lda mox,x             ; and does it stand in forest? the check
        sta cx                 ; used to sit only in the bullet branch
        lda moy,x              ; below, so enemy TANKS never got a
        sta cy                 ; priority flag - which is why only the
        stx muxtmp             ; player ever went behind the trees
        jsr tileunder
        ldx muxtmp
        cmp #tileforest
        bne @tankfront
        lda #1
        sta objpri,x
        jmp @gcom
@tankfront
        lda #0
        sta objpri,x
        jmp @gcom
@isbul  lda mox,x             ; enemy bullet
        sec
        sbc #bulletdx
        sta objx,x
        lda moy,x
        sec
        sbc #bulletdy
        sta objy,x
        lda mox,x             ; is this object in the trees?
        sta cx
        lda moy,x
        sta cy
        stx muxtmp
        jsr tileunder
        ldx muxtmp
        cmp #tileforest
        bne @nohide
        lda #1
        sta objpri,x
        jmp @gcom
@nohide lda #0
        sta objpri,x
@gcom   lda moptr,x
        sta objp,x
        lda mocol,x
        sta objc,x
        cpx #4                ; only tanks carry a power-up
        bcs @gnext
        lda mobonus,x
        beq @gnext
        lda tick              ; flash the carrier red about 6 times a
        and #4                ; second so it reads as a flash
        beq @gnext
        lda #2
        sta objc,x
@gnext  inx
        cpx #8
        beq @gdone
        jmp @glp              ; the loop body outgrew branch range
@gdone

        ldx #0                ; the four player shells, objects 8-11
@plp    lda pbactive,x
        bne @plive
        lda #255
        sta objy+8,x
        jmp @pnext
@plive  lda #0
        sta objpri+8,x        ; shells are never hidden
        lda pbx,x
        sec
        sbc #bulletdx
        sta objx+8,x
        lda pby,x
        sec
        sbc #bulletdy
        sta objy+8,x
        lda #bulletptr              ; the shared bullet sprite
        sta objp+8,x
        lda #4                ; purple - the same as the enemies'
        sta objc+8,x           ; shells. nothing else on the field is
                                ; purple, so a shell is never mistaken
                                ; for ice, for a light red tank, or for
                                ; anything else.
@pnext  inx
        cpx #4
        bne @plp

        jsr dronesprite       ; the bonus drone, in enemy slot 0's place
        jsr strikesprites     ; and the strike's drones, in any spare
        jsr osort             ; enemy-bullet places
        jsr buildlist
        rts

; ------------------------------------------------------------
; osort   the "ocean" sort (multiplexer.md 2.1): an insertion
;         sort over an index array that PERSISTS between frames,
;         so when objects have barely moved it does almost
;         nothing.
;   in:   sortorder (seeded 0..11 once by initmux, never reset),
;         objy = object y, 255 for unused
;   uses: a, x, y; self-modifies @reload+1
; ------------------------------------------------------------
osort   ldx #0
@loop   ldy sortorder+1,x
        lda objy,y
        ldy sortorder,x
        cmp objy,y
        bcs @skip
        stx @reload+1
@swap   lda sortorder+1,x
        sta sortorder,x
        tya
        sta sortorder+1,x
        cpx #0
        beq @reload
        dex
        ldy sortorder+1,x
        lda objy,y
        ldy sortorder,x
        cmp objy,y
        bcc @swap
@reload ldx #0
@skip   inx
        cpx #muxobjs-1
        bcc @loop
        rts

; ------------------------------------------------------------
; buildlist   walk the sorted order and build the display list,
;             applying the reuse test: entry n takes the sprite
;             entry n-6 had, so it needs 21 lines of clearance
;             from it. written into the bank the irq chain is not
;             reading, and the bank flipped in one store.
;   uses: a, x, y, cy2, srcidx, sidx2, cnt2, dspoff
; ------------------------------------------------------------
buildlist
        lda dspread
        eor #1
        sta dspwrite
        beq @off0
        lda #muxobjs          ; bank 1 starts 12 entries in
        sta dspoff
        jmp @haveoff
@off0   lda #0
        sta dspoff
@haveoff
        lda #0
        sta cnt2
        ldx #0
@lp     ldy sortorder,x
        lda objy,y
        cmp #255
        beq @done             ; the rest are inactive
        sta cy2
        sty srcidx
        lda cnt2
        cmp #muxpool
        bcc @accept           ; the first six always fit
        sec
        sbc #muxpool
        clc
        adc dspoff
        tay
        lda cy2
        sec
        sbc dspy,y            ; gap to the entry reusing this sprite
        cmp #21
        bcc @reject
@accept lda cnt2
        clc
        adc dspoff
        tay
        lda cy2
        sta dspy,y
        stx sidx2
        ldx srcidx
        lda objx,x
        sta dspx,y
        lda objp,x
        sta dspp,y
        lda objc,x
        sta dspc,y
        lda objpri,x
        sta dsppri,y
        ldx sidx2
        inc cnt2
@reject inx
        cpx #muxobjs
        bne @lp
@done   ldy dspwrite
        lda cnt2
        sta dspcnt,y
        lda dspwrite
        sta dspread           ; the atomic flip
        rts

; ------------------------------------------------------------
; muxirq   the raster chain. muxidx is the next display entry to
;          write and muxslot the hardware sprite it goes to,
;          cycling 0-5 over sprites 2-7. muxidx 0 means the
;          frame-top event, where the first up-to-6 entries are
;          written and the enable bits set.
;   uses: a, x, y
; ------------------------------------------------------------
muxirq  lda endgame           ; the ending: no enemies, no shells, so the
        beq @normal           ; pool is idle - but sprite 7 is the missile
        lda d015              ; and the pool must not switch it off
        and #%00000011
        ldx endtimer          ; ...once it is falling. during the pause
        cpx #launchdelay      ; before launch sprite 7 still holds
        bcc @nomiss           ; whatever it last showed in the game
        ora #%10000000
@nomiss sta d015
        lda #muxtop
        sta $d012
        rts
@normal lda gameover
        bne @hide
        lda inattract
        bne @hide
        lda intitle           ; the title path below is too long now
        bne @hide             ; for a branch to reach @run over it
        jmp @run
@hide   lda d015
        and #%00000011        ; pool off; the players' own two remain
        sta d015              ; (
        lda intitle           ; below while the scroller runs). title
                               ; or briefing: the scroller runs,
        ora inattract         ; which needs a second interrupt a frame
        beq @plain            ; to fine-scroll row 24 on its own
        lda scrphase
        bne @atrow
        lda #d016title        ; top of the frame: 38 columns for the
        sta $d016             ; whole title and briefing, not just the
                               ; scroller's row. narrowing row 24 alone
                               ; pushed the black border into a grey row
                               ; as a notch each side; a mask sprite then
                               ; hid the notch but left a grey gap. with
                               ; every row the same width there is
                               ; nothing to hide - nothing on either
                               ; screen uses columns 0, 38 or 39.
        jsr scrollertick
        lda #1
        sta scrphase
        lda #scrline          ; and come back just above row 24
        sta $d012
        jmp @hdone
@atrow  lda scrfine           ; row 24: the same 38 columns, fine-
        ora #d016scroll       ; scrolled, so characters slide in from
        sta $d016             ; under the right border and away under
                               ; the left
        lda #0
        sta scrphase
        lda #muxtop
        sta $d012
        jmp @hdone
@plain  lda #d016norm         ; game over: no scroller, and never leave
        sta $d016             ; the screen fine-scrolled
        lda d015              ; nor the mask sprite showing
        and #%01111111
        sta d015
        lda #0
        sta scrphase
        lda #muxtop
        sta $d012
@hdone  lda #0
        sta muxidx
        sta muxslot
        rts
@run    lda muxidx            ; mid-frame: carry on with the bank and
        bne @cont             ; count latched at the top
        lda dspread           ; top of the frame: take the bank ONCE and
        sta muxbank           ; hold it for the whole frame. this used to
        tay                   ; re-read dspread on every interrupt, and
        lda dspcnt,y          ; buildsprites can flip it at any moment -
        sta curcnt            ; so half a frame came from the old list and
        lda #0                ; half from the new, and one shell could be
        sta muxslot           ; drawn twice, at its old place and its new
        lda curcnt            ; enable however many the frame uses
        cmp #muxpool+1
        bcc @okp
        lda #muxpool
@okp    tax
        lda d015
        and #%00000011
        ora enmask,x
        sta d015
@ftlp   lda muxidx
        cmp curcnt
        bcs @arm
        cmp #muxpool
        bcs @arm
        jsr writeentry
        jmp @ftlp
@cont   jsr writeentry
@arm    lda muxidx
        cmp curcnt
        bcs @endframe
        lda muxbank           ; the latched bank, not the live one
        beq @a0
        lda #muxobjs
        jmp @a1
@a0     lda #0
@a1     clc
        adc muxidx
        tay
        lda dspy,y
        sec
        sbc #3                ; margin to get the write in
        sta $d012
        cmp $d012             ; multiplexer.md 2.5 - already past it?
        bcc @cont             ; yes: do this one now rather than wait
        rts
@endframe
        lda #muxtop
        sta $d012
        lda #0
        sta muxidx
        sta muxslot
        rts

; ------------------------------------------------------------
; writeentry   push display entry muxidx to the hardware sprite
;              muxslot names (0-5 = sprites 2-7), then advance
;              both. unrolled per sprite with the register
;              addresses baked in (multiplexer.md 2.4).
;   uses: a, y
; ------------------------------------------------------------
writeentry
        ldx muxslot           ; hardware sprite 2+muxslot, as a bit
        lda spritebit,x
        sta muxbit
        lda muxbank           ; the bank latched at the top of the frame
        beq @b0
        lda #muxobjs
        jmp @b1
@b0     lda #0
@b1     clc
        adc muxidx
        tay                   ; y = bank offset + entry index
        ldx muxslot           ; multiplexer.md 2.4 - straight to the
        lda slotlo,x          ; block for this hardware sprite. the
        sta muxvec            ; compare chain this replaces cost four
        lda slothi,x          ; more instructions for the last slot
        sta muxvec+1          ; than the first, and the later slots are
        jmp (muxvec)          ; exactly the ones with least slack
wes7     lda dspy,y            ; sprite 7
        sta $d00f
        lda dspx,y
        sta $d00e
        lda dspp,y
        sta $47ff
        lda dspc,y
        sta $d02e
        jmp wadv
wes2     lda dspy,y
        sta $d005
        lda dspx,y
        sta $d004
        lda dspp,y
        sta $47fa
        lda dspc,y
        sta $d029
        jmp wadv
wes3     lda dspy,y
        sta $d007
        lda dspx,y
        sta $d006
        lda dspp,y
        sta $47fb
        lda dspc,y
        sta $d02a
        jmp wadv
wes4     lda dspy,y
        sta $d009
        lda dspx,y
        sta $d008
        lda dspp,y
        sta $47fc
        lda dspc,y
        sta $d02b
        jmp wadv
wes5     lda dspy,y
        sta $d00b
        lda dspx,y
        sta $d00a
        lda dspp,y
        sta $47fd
        lda dspc,y
        sta $d02c
        jmp wadv
wes6     lda dspy,y
        sta $d00d
        lda dspx,y
        sta $d00c
        lda dspp,y
        sta $47fe
        lda dspc,y
        sta $d02d
wadv    lda dsppri,y          ; behind the characters if this object is
        beq @clrpri            ; in forest, in front otherwise. this has
        lda d01b               ; to live HERE, not in one sprite's block:
        ora muxbit             ; when the blocks were split for the jump
        jmp @setpri            ; table it ended up inside sprite 6's,
@clrpri lda muxbit             ; so five of the six pool sprites drove
        eor #$ff               ; straight over the trees. y and muxbit
        and d01b               ; are still live at this point.
@setpri sta d01b
        inc muxidx
        inc muxslot
        lda muxslot
        cmp #muxpool
        bne @done
        lda #0
        sta muxslot           ; wrap: back round to sprite 2
@done   rts

; ------------------------------------------------------------
; initmux   seed the persistent sort order once at startup. it is
;           never reset afterwards - that is the point of it.
;   uses: a, x
; ------------------------------------------------------------
initmux ldx #0
@lp     txa
        sta sortorder,x
        lda #255
        sta objy,x
        inx
        cpx #muxobjs
        bne @lp
        lda #0
        sta muxidx
        sta muxslot
        sta dspread
        sta dspcnt
        sta dspcnt+1
        rts

; enable-bit masks for sprites 2-7, indexed by how many of the
; six the frame actually uses.
enmask  byte %00000000,%00000100,%00001100,%00011100
        byte %00111100,%01111100,%11111100
spritebit byte %00000100,%00001000,%00010000,%00100000
        byte %01000000,%10000000
; where each hardware sprite's register writes live
slotlo  byte <wes2,<wes3,<wes4,<wes5,<wes6,<wes7
slothi  byte >wes2,>wes3,>wes4,>wes5,>wes6,>wes7
; NOTE: these must be global labels. as @s2..@s7 they were
; local to writeentry, the table is under a different global
; label, and the assembler resolved them to nothing without
; complaining - the dispatch jumped into the weeds.


; ------------------------------------------------------------
; detectstd   figure out pal (312 lines) vs ntsc (263 lines)
;   out:  videostd = 1 (pal) or 0 (ntsc)
;   uses: a, x
;   note: waits for raster bit 8 ($d011 bit 7) to set, then
;         checks whether it is still set ~20 lines later. ntsc
;         only holds it for 7 lines (256-262) before wrapping;
;         pal holds it for 56 (256-311). not simulator-testable
;         (needs real vic-ii raster behaviour) - check in vice.
; ------------------------------------------------------------
detectstd
@w0     lda d011         ; FIRST wait until the raster is back below
        bmi @w0           ; 256, so the next step catches the moment it
@w1     lda d011          ; crosses - without this the routine could
        bpl @w1           ; begin anywhere inside the 256+ window. on
                           ; pal that window is 56 lines wide, so
                           ; entering it near the end left fewer than
                           ; the 20 lines this then waits, the raster
                           ; wrapped, and a pal machine reported ntsc.
                           ; where in the window it landed depended on
                           ; how long everything before it took - which
                           ; is why this changed when initchars did.
        ldx #20
@w2     lda d012
@w3     cmp d012
        beq @w3
        dex
        bne @w2
        lda d011
        bmi @ispal
        lda #0
        sta videostd
        rts
@ispal  lda #1
        sta videostd
        rts

; ------------------------------------------------------------
; settimer   program cia1 timer a for a real 50hz tick on
;            whichever machine this is, using the clock ratio
;            (985248hz pal, 1022727hz ntsc). latch = round(clock/50)-1.
;   uses: a
; ------------------------------------------------------------
settimer
        lda videostd
        bne @pal
@ntsc   lda #<20454      ; ntsc: 1022727/50 - 1, rounded
        sta $dc04
        lda #>20454
        sta $dc05
        rts
@pal    lda #<19704      ; pal: 985248/50 - 1, rounded
        sta $dc04
        lda #>19704
        sta $dc05
        rts

; ------------------------------------------------------------
; initplayers   turn on sprites 0/1 as the two tanks, placed at
;               the spawn points readlevel found in the level data
;   uses: a
; ------------------------------------------------------------
initplayers
        lda #0
        sta d01c          ; hires. multicolour was tried and looked
                           ; worse: halving the horizontal resolution
                           ; costs more shape than the extra colours
                           ; buy back at 16 pixels across
        lda #%00000011
        sta d015          ; only sprites 0 and 1 are ours to enable;
                           ; 2-7 are the multiplexer's, and muxirq sets
                           ; their bits itself each frame
        lda #0                ; and start travelling the way they face
        sta p1travel
        sta p2travel
        lda #tankptr          ; both start facing up, tread phase 0
        clc
        adc p1facing
        adc p1facing
        sta $47f8
        lda #tankptr
        clc
        adc p2facing
        adc p2facing
        sta $47f9
        lda #6            ; player 1 dark blue, player 2 yellow
        sta d027
        lda #7
        sta d027+1
        lda #1            ; white
        sta d027+2
        sta d027+3
        ldx p1facing
        lda p1x
        sec
        sbc dirdx,x
        sta $d000
        lda p1y
        sec
        sbc dirdy,x
        sta $d001
        ldx p2facing
        lda p2x
        sec
        sbc dirdx,x
        sta $d002
        lda p2y
        sec
        sbc dirdy,x
        sta $d003
        lda $d010
        and #%11111100    ; clear bits 0/1, rebuild from the spawn msb flags
        ora p1xmsb
        sta $d010
        lda p2xmsb
        beq @done
        lda $d010
        ora #%00000010
        sta $d010
@done   rts

; ------------------------------------------------------------
; updateplayers   read both joysticks, move each tank, push the
;                 new positions to the hardware sprites.
;   uses: a, x, y, and everything movetank uses
;   note: player 1's box is the "other" tank for player 2's
;         check, and vice versa; player 1 is processed first,
;         so player 2 sees player 1's already-updated position
;         this tick while player 1 saw player 2's from last
;         tick. harmless for a 1px/tick game speed.
; ------------------------------------------------------------
updateplayers
        inc movephase         ; the movement clock, advanced where the
                               ; movement it gates actually happens
        lda #$ff              ; force the keyboard column-select
        sta $dc00              ; register (also joystick 2's port)
                                ; to "no column selected" before
                                ; reading either joystick this tick -
                                ; player 1's port shares lines with
                                ; the keyboard matrix, and scnkey now
                                ; runs less often than it used to (see
                                ; irq's header comment) - this is a
                                ; defensive guarantee that a stale
                                ; column-select state can never make
                                ; a joystick read look wrong,
                                ; regardless of scnkey's exact timing.
        lda p1alive           ; the block below outgrew branch range, so
        bne @p1on             ; these reach @skipp1 by jmp
        jmp @skipp1
@p1on   lda p1respawn         ; blown up - off the field until it counts
        beq @p1up             ; back in
        jmp @skipp1
@p1up   lda movephase         ; and not on the skipped tick
        and #movemask
        cmp #movemask
        bne @p1go
        jmp @skipp1
@p1go
        lda joy1
        and #31
        sta cjoy
        lda p1x
        sta cx
        lda p1y
        sta cy
        lda p1facing
        sta cfacing
        lda p1pend            ; each tank carries its own buffered turn
        sta cpend
        lda p1slide
        sta cslide
        lda p1travel
        sta ctravel
        lda p1turn
        sta cturn
        jsr buildotherlist_p1
        jsr movetank
        lda cpend
        sta p1pend
        lda cslide
        sta p1slide
        lda ctravel
        sta p1travel
        lda cturn
        sta p1turn
        lda cx
        cmp p1x               ; did it actually travel this tick?
        bne @p1moved
        lda cy
        cmp p1y
        beq @p1still
@p1moved
        inc p1step            ; tracks advance a link every 4 pixels
        lda p1step
        and #3
        bne @p1still
        lda p1anim
        eor #1
        sta p1anim
@p1still
        lda cx
        sta p1x
        lda cy
        sta p1y
        lda cfacing
        sta p1facing
@skipp1
        lda p2alive           ; same here: out of branch range now
        bne @p2on
        jmp @skipp2
@p2on   lda p2respawn
        beq @p2up
        jmp @skipp2
@p2up   lda movephase
        and #movemask
        cmp #movemask
        bne @p2go
        jmp @skipp2
@p2go
        lda joy2
        and #31
        sta cjoy
        lda p2x
        sta cx
        lda p2y
        sta cy
        lda p2facing
        sta cfacing
        lda p2pend
        sta cpend
        lda p2slide
        sta cslide
        lda p2travel
        sta ctravel
        lda p2turn
        sta cturn
        jsr buildotherlist_p2
        jsr movetank
        lda cpend
        sta p2pend
        lda cslide
        sta p2slide
        lda ctravel
        sta p2travel
        lda cturn
        sta p2turn
        lda cx
        cmp p2x
        bne @p2moved
        lda cy
        cmp p2y
        beq @p2still
@p2moved
        inc p2step
        lda p2step
        and #3
        bne @p2still
        lda p2anim
        eor #1
        sta p2anim
@p2still
        lda cx
        sta p2x
        lda cy
        sta p2y
        lda cfacing
        sta p2facing
@skipp2
        ldx p1facing
        lda p1x
        sec
        sbc dirdx,x
        sta $d000
        lda p1y
        sec
        sbc dirdy,x
        sta $d001
        ldx p2facing
        lda p2x
        sec
        sbc dirdx,x
        sta $d002
        lda p2y
        sec
        sbc dirdy,x
        sta $d003
        lda p1shield          ; a shielded tank flashes, so the player
        beq @p1normal         ; can see the protection running out
        lda tick
        and #4
        beq @p1normal
        lda #1                ; white
        jmp @p1col
@p1normal
        lda #6                ; player 1 dark blue
@p1col  sta d027
        lda p2shield
        beq @p2normal
        lda tick
        and #4
        beq @p2normal
        lda #1
        jmp @p2col
@p2normal
        lda #7                ; player 2 yellow
@p2col  sta d027+1

        lda p1x               ; forest hides what drives through it:
        sta cx                 ; put the sprite behind the characters
        lda p1y                ; while its middle is in the trees
        sta cy
        jsr tileunder
        cmp #tileforest
        beq @p1hide
        lda d01b
        and #%11111110
        jmp @p1pri
@p1hide lda d01b
        ora #%00000001
@p1pri  sta d01b
        lda p2x
        sta cx
        lda p2y
        sta cy
        jsr tileunder
        cmp #tileforest
        beq @p2hide
        lda d01b
        and #%11111101
        jmp @p2pri
@p2hide lda d01b
        ora #%00000010
@p2pri  sta d01b

        lda p1facing          ; pointer = tankptr + facing*2 + tread
        asl a                  ; phase, so a turn shows the right frame
        clc                    ; at once and the tracks keep their
        adc p1anim             ; animation across it
        clc
        adc #tankptr
        sta $47f8
        lda p2facing
        asl a
        clc
        adc p2anim
        clc
        adc #tankptr
        sta $47f9
        rts

; ------------------------------------------------------------
; movetank   try to move one tank 1px per tick from its
;            joystick input. cx/cy are updated in place if the
;            move is clear; cfacing tracks last-pressed
;            direction (0=up 1=down 2=left 3=right) regardless
;            of whether the move succeeded, so a tank pushing
;            into a wall still turns to face that way.
;            only one direction acts per tick (priority
;            up > down > left > right) - battle city tanks
;            never move diagonally.
;   in:   cjoy (joystick bits, active low), cx, cy, cfacing,
;         otherboxx/otherboxy/othercount (every other tank's
;         current box - see buildotherlist_p1/p2/enemy)
;   out:  cx, cy, cfacing updated
;   uses: a, x, y, and everything the check* routines use
; ------------------------------------------------------------
movetank
        lda #255              ; decode the held direction into creq
        sta creq
        lda cjoy
        and #%00000001
        bne @n0
        lda #0
        sta creq
        jmp @havereq
@n0     lda cjoy
        and #%00000010
        bne @n1
        lda #1
        sta creq
        jmp @havereq
@n1     lda cjoy
        and #%00000100
        bne @n2
        lda #2
        sta creq
        jmp @havereq
@n2     lda cjoy
        and #%00001000
        bne @havereq
        lda #3
        sta creq
@havereq
        lda creq
        cmp #255
        bne @held
        lda #255              ; stick released - drop any buffered turn
        sta cpend
        lda cslide            ; but on ice it carries on a little way
        beq @idle              ; before it settles
        dec cslide
        lda cfacing
        jsr trymove
        bcc @idle             ; slid into something - settle instead
        rts
@idle   lda #0
        sta cslide
        sta cturn             ; at rest there is no corner to be early
                               ; for, so the next blocked press is a
                               ; turn-to-face and must take effect at
                               ; once. the grace period only makes
                               ; sense for a tank already rolling.
        jmp @settle           ; MUST jump: falling through into @held
                               ; stored the accumulator (0 = up) as the
                               ; buffered turn, so an idle tank drove
                               ; upward for ever
@held   sta cpend             ; remember what was asked for
        jsr tileunder         ; ice keeps the tank moving for a moment
        cmp #tileice          ; after the input stops
        bne @noice
        lda #iceslide
        sta cslide
@noice

        lda cpend             ; can we take the requested direction now?
        jsr trymove
        bcc @blocked
        lda cpend             ; yes - the turn takes
        sta cfacing
        sta ctravel           ; and this is the way we are now rolling
        lda #turnhold         ; a fresh grace period for the next turn
        sta cturn
        lda #255
        sta cpend
        rts

; a blocked request is ambiguous: the player either wants to corner
; and has pressed a little early, or wants to face the wall beside
; them and shoot it. telling them apart needs time, not geometry.
; for a short while the tank carries on the way it was going - facing
; that way, so it never slides sideways - and the buffered turn takes
; the moment a gap appears. if the way stays shut for longer than
; that, the press was a turn-to-face: the gun comes round and the
; tank stops.
@blocked
        lda cturn             ; still within the grace period?
        beq @facewall
        dec cturn
        lda ctravel           ; carry on, pointing where it is going
        sta cfacing
        jsr trymove
        bcs @rolled
        lda cpend             ; the old way is shut too - nothing to do
        sta cfacing           ; but turn and stop
        lda #0
        sta cturn
@rolled rts
@facewall
        lda cpend             ; grace is up: face the wall and stay put
        sta cfacing
        rts

; nothing held. the tank stops - but it stops wherever it happened to
; be, often part-way across a tile and part-way through a glide, so it
; would come to rest straddling two character squares. ease both axes
; onto the nearest gridline, a pixel a tick, through the ordinary
; collision checks so it can never settle into a wall. once aligned all
; four tests fall through and this costs almost nothing.
@settle lda cx
        sec
        sbc #24
        and #7
        beq @idley
        cmp #4
        bcs @ix_r
        jsr checkleft
        bcc @idley
        dec cx
        jmp @idley
@ix_r   jsr checkright
        bcc @idley
        inc cx
@idley  lda cy
        sec
        sbc #50
        and #7
        beq @idone
        cmp #4
        bcs @iy_d
        jsr checkup
        bcc @idone
        dec cy
        rts
@iy_d   jsr checkdown
        bcc @idone
        inc cy
@idone  rts

; ------------------------------------------------------------
; trymove   attempt one pixel of travel in direction a, easing the
;           cross axis toward the grid first so the tank lines up
;           with the lane it is entering.
;   in:   a = 0 up, 1 down, 2 left, 3 right
;   out:  carry set if the tank moved; on failure the cross-axis
;         ease is undone, so a refused move leaves it exactly where
;         it was rather than nudged sideways.
;   uses: a, x, y, oldcx / oldcy
; ------------------------------------------------------------
trymove cmp #0
        bne @t1
        jsr glidex
        jsr checkup
        bcc @nox
        dec cy
        sec
        rts
@t1     cmp #1
        bne @t2
        jsr glidex
        jsr checkdown
        bcc @nox
        inc cy
        sec
        rts
@t2     cmp #2
        bne @t3
        jsr glidey
        jsr checkleft
        bcc @noy
        dec cx
        sec
        rts
@t3     jsr glidey
        jsr checkright
        bcc @noy
        inc cx
        sec
        rts
@nox    jsr unsnapx
        clc
        rts
@noy    jsr unsnapy
        clc
        rts

; ------------------------------------------------------------
; glidex / glidey  ease the axis the tank is NOT travelling along
;                  toward the tile grid, ONE PIXEL A TICK, instead of
;                  snapping it there in a single jump.
;
;   the grid is relative to the field origin (24,50), not to a raw
;   multiple of 8: only x's origin happens to be 8-aligned, so a
;   naive "and #$f8" on y snaps to the wrong grid entirely.
;
;   the original "and #$f8" snapped in one step and always downward,
;   so a tank almost at the next tile was yanked up to 7 pixels BACK
;   the moment the stick moved. rounding to the nearest line first cut
;   that to 4. easing a pixel at a time removes it altogether: the
;   tank drifts into the lane over a few ticks while still driving
;   forward, which is what reads as cornering smoothly rather than
;   snapping to a grid.
;
;   this is only safe because checkup/checkdown/checkleft/checkright
;   each test BOTH tiles the tank spans on the cross axis, so a tank
;   sitting between two lanes collides correctly while it eases in.
;   code that assumed alignment before the check would need the snap.
;
;   the old value is kept so a refused turn can be undone. the snap
;   has to happen BEFORE the collision check (the check tests the
;   aligned position), and without the undo a tank held against a
;   wall is displaced sideways every tick for a move it never makes.
;   uses: a, oldcx / oldcy
; ------------------------------------------------------------
glidex  lda cx
        sta oldcx
        sec
        sbc #24
        and #7
        beq @ok               ; already on a gridline
        cmp #4
        bcs @plus
        dec cx                ; nearer the line below - ease toward it
        rts
@plus   inc cx
@ok     rts
unsnapx lda oldcx
        sta cx
        rts
glidey  lda cy
        sta oldcy
        sec
        sbc #50
        and #7
        beq @ok
        cmp #4
        bcs @plus
        dec cy
        rts
@plus   inc cy
@ok     rts
unsnapy lda oldcy
        sta cy
        rts


; ------------------------------------------------------------
; tileunder   the tile beneath the middle of the tank at (cx,cy).
;   out:  a = tile value, 0 if off the field
;   uses: a, x, y, trow, tcol
; ------------------------------------------------------------
tileunder
        lda cx
        clc
        adc #8
        jsr xtotile
        bcc @none
        sta tcol
        lda cy
        clc
        adc #8
        jsr ytotile
        bcc @none
        sta trow
        jmp tileat
@none   lda #0
        rts

; ------------------------------------------------------------
; solidfortank / solidforshell   the terrain types part company
;   here: a river stops a tank but a shell flies over it, and
;   forest and ice stop neither. everything else - armour, the
;   base, brick in any state - stops both.
;   in:   a = tile value
;   out:  carry set if it blocks
;   uses: a
; ------------------------------------------------------------
solidfortank
        cmp #brickmask        ; $10+ is brick or armour
        bcs @yes
        cmp #tileforest
        beq @no
        cmp #tileice
        beq @no
        cmp #0
        beq @no
@yes    sec
        rts
@no     clc
        rts

; ------------------------------------------------------------
; checkup/checkdown/checkleft/checkright
;   in:   cx, cy (current, already axis-snapped this tick)
;   out:  carry set = the 1px move is clear, carry clear = blocked
;   uses: a, x, y, trow, tcol, tmpx, tmpy
;   each checks the two field cells the tank's leading edge
;   would enter, then the tentative new box against the other
;   tank's box.
; ------------------------------------------------------------
checkup lda cy
        sec
        sbc #1
        jsr ytotile
        bcc @blocked
        sta trow
        lda cx
        jsr xtotile
        bcc @blocked
        sta tcol
        jsr tileat
        jsr solidfortank
        bcs @blocked
        lda cx
        clc
        adc #15
        jsr xtotile
        bcc @blocked
        sta tcol
        jsr tileat
        jsr solidfortank
        bcs @blocked
        lda cx
        sta tmpx
        lda cy
        sec
        sbc #1
        sta tmpy
        jmp checkoverlap
@blocked clc
        rts

checkdown
        lda cy
        clc
        adc #16
        jsr ytotile
        bcc @blocked
        sta trow
        lda cx
        jsr xtotile
        bcc @blocked
        sta tcol
        jsr tileat
        jsr solidfortank
        bcs @blocked
        lda cx
        clc
        adc #15
        jsr xtotile
        bcc @blocked
        sta tcol
        jsr tileat
        jsr solidfortank
        bcs @blocked
        lda cx
        sta tmpx
        lda cy
        clc
        adc #1
        sta tmpy
        jmp checkoverlap
@blocked clc
        rts

checkleft
        lda cx
        sec
        sbc #1
        jsr xtotile
        bcc @blocked
        sta tcol
        lda cy
        jsr ytotile
        bcc @blocked
        sta trow
        jsr tileat
        jsr solidfortank
        bcs @blocked
        lda cy
        clc
        adc #15
        jsr ytotile
        bcc @blocked
        sta trow
        jsr tileat
        jsr solidfortank
        bcs @blocked
        lda cx
        sec
        sbc #1
        sta tmpx
        lda cy
        sta tmpy
        jmp checkoverlap
@blocked clc
        rts

checkright
        lda cx
        clc
        adc #16
        jsr xtotile
        bcc @blocked
        sta tcol
        lda cy
        jsr ytotile
        bcc @blocked
        sta trow
        jsr tileat
        jsr solidfortank
        bcs @blocked
        lda cy
        clc
        adc #15
        jsr ytotile
        bcc @blocked
        sta trow
        jsr tileat
        jsr solidfortank
        bcs @blocked
        lda cx
        clc
        adc #1
        sta tmpx
        lda cy
        sta tmpy
        jmp checkoverlap
@blocked clc
        rts

; ------------------------------------------------------------
; checkoverlap   shared tail: tmpx/tmpy already passed the tile
;                probes, now test against every other tank's box
;   in:   tmpx, tmpy (tentative new position), otherboxx/
;         otherboxy/othercount
;   out:  carry set = clear to move, carry clear = blocked
;   uses: a
; ------------------------------------------------------------
checkoverlap
        jsr overlapcheck
        bcs @blocked
        sec
        rts
@blocked clc
        rts

; ------------------------------------------------------------
; overlapcheck   would a 16x16 box at (tmpx,tmpy) overlap ANY of
;                the othercount other-tank boxes currently listed
;                in otherboxx/otherboxy? (built by whichever of
;                updateplayers/updateenemies is about to move a
;                tank - see their headers.)
;   out:  carry set = overlap (blocked), clear = no overlap
;   uses: a, x
; ------------------------------------------------------------
overlapcheck
        ldx #0
@lp     cpx othercount
        beq @noover
        lda tmpx
        clc
        adc #16
        cmp otherboxx,x
        bcc @next
        beq @next
        lda otherboxx,x
        clc
        adc #16
        cmp tmpx
        bcc @next
        beq @next
        lda tmpy
        clc
        adc #16
        cmp otherboxy,x
        bcc @next
        beq @next
        lda otherboxy,x
        clc
        adc #16
        cmp tmpy
        bcc @next
        beq @next
        sec
        rts
@next   inx
        jmp @lp
@noover clc
        rts

; ------------------------------------------------------------
; buildotherlist_p1   list every tank EXCEPT player 1, for the
;                     overlap check about to run on player 1's
;                     move: player 2 (if alive) + every active
;                     enemy. tanks now block each other's
;                     movement - they used to be able to drive
;                     straight through one another.
;   out:  otherboxx/otherboxy/othercount
;   uses: a, x, y
; ------------------------------------------------------------
buildotherlist_p1
        ldx #0
        lda p2alive
        beq @skipp2
        lda p2x
        sta otherboxx,x
        lda p2y
        sta otherboxy,x
        inx
@skipp2 ldy #0
@elp    lda moactive,y
        beq @enext
        lda mox,y
        sta otherboxx,x
        lda moy,y
        sta otherboxy,x
        inx
@enext  iny
        cpy #4
        bne @elp
        stx othercount
        rts

; ------------------------------------------------------------
; buildotherlist_p2   same as buildotherlist_p1, but for player
;                     2's move: player 1 (if alive) + every
;                     active enemy.
;   out:  otherboxx/otherboxy/othercount
;   uses: a, x, y
; ------------------------------------------------------------
buildotherlist_p2
        ldx #0
        lda p1alive
        beq @skipp1
        lda p1x
        sta otherboxx,x
        lda p1y
        sta otherboxy,x
        inx
@skipp1 ldy #0
@elp    lda moactive,y
        beq @enext
        lda mox,y
        sta otherboxx,x
        lda moy,y
        sta otherboxy,x
        inx
@enext  iny
        cpy #4
        bne @elp
        stx othercount
        rts

; ------------------------------------------------------------
; buildotherlist_enemy   list every tank EXCEPT the enemy about
;                        to move (selfidx): both players (if
;                        alive) + every OTHER active enemy.
;   in:   selfidx = the moving enemy's index (0-3)
;   out:  otherboxx/otherboxy/othercount
;   uses: a, x, y
; ------------------------------------------------------------
buildotherlist_enemy
        ldx #0
        lda p1alive
        beq @skipp1
        lda p1respawn         ; a player waiting to respawn is not on the
        bne @skipp1           ; field and must not be an obstacle. they
        lda p1x               ; now wait ON the spawn point, and an enemy
                               ; parked there was boxed in by the hidden
                               ; player on every side - it never moved,
                               ; and the player never came back
        sta otherboxx,x
        lda p1y
        sta otherboxy,x
        inx
@skipp1 lda p2alive
        beq @skipp2
        lda p2respawn
        bne @skipp2
        lda p2x
        sta otherboxx,x
        lda p2y
        sta otherboxy,x
        inx
@skipp2 ldy #0
@elp    cpy selfidx
        beq @enext
        lda moactive,y
        beq @enext
        lda mox,y
        sta otherboxx,x
        lda moy,y
        sta otherboxy,x
        inx
@enext  iny
        cpy #4
        bne @elp
        stx othercount
        rts

; ------------------------------------------------------------
; xtotile   convert a field-relative pixel x to a tile column
;   in:   a = pixel x (absolute vic coordinate)
;   out:  a = tile column (0-25), carry set if in range,
;         clear if out of range (caller treats as blocked)
;   uses: a
; ------------------------------------------------------------
xtotile sec
        sbc #24              ; field left edge
        bcc @bad
        cmp #26*8
        bcs @bad
        lsr a
        lsr a
        lsr a
        sec
        rts
@bad    clc
        rts

; ------------------------------------------------------------
; ytotile   convert a field-relative pixel y to a tile row
;   in:   a = pixel y (absolute vic coordinate)
;   out:  a = tile row (0-24), carry set if in range,
;         clear if out of range
;   uses: a
; ------------------------------------------------------------
ytotile sec
        sbc #50              ; field top edge
        bcc @bad
        cmp #25*8
        bcs @bad
        lsr a
        lsr a
        lsr a
        sec
        rts
@bad    clc
        rts

; ------------------------------------------------------------
; tileat   look up field[trow*26+tcol]
;   in:   trow, tcol
;   out:  a = field value (0-3)
;   uses: a, x, lvlptr (reused as a scratch pointer here - this
;         only runs from the main loop, never during readlevel)
; ------------------------------------------------------------
; ------------------------------------------------------------
; tileat   look up field[trow*26+tcol]
;   in:   trow, tcol
;   out:  a = field value (0-3)
;   uses: a, x, y, lvlptr
;   note: was a loop adding 26 per row (up to ~450 cycles at
;         row 24, worst case ~900 cycles per collision check
;         since callers probe twice) - replaced with a
;         compile-time offset table (fieldrowlo/fieldrowhi),
;         since a tile row's byte offset is fixed at assemble
;         time. this runs on every single movement and bullet
;         check, so its cost was a real, direct contributor to
;         the "noticeable pausing" report - worse specifically
;         as enemies converge on the base, since that's the
;         highest row values and the most simultaneous checks.
; ------------------------------------------------------------
tileat  ldx trow
        lda #<field
        clc
        adc fieldrowlo,x
        sta lvlptr
        lda #>field
        adc fieldrowhi,x
        sta lvlptr+1
        ldy tcol
        lda (lvlptr),y
        rts

; ==============================================================
; STAGE 3: shooting, wall destruction, base
; ==============================================================

; ------------------------------------------------------------
; updatebullets   handle fire input for both tanks, move
;                 whichever player bullets are active, and check
;                 each against the other player and every enemy.
;   uses: a, x, y, and everything updatebullet/pointinbox/
;         spawnbullet*/hittank*/killenemy use
; ------------------------------------------------------------
; firebullet   try to launch a shell for the player named in
;              fireown (0 or 1). each player owns a pair of slots
;              - player 1 has 0 and 1, player 2 has 2 and 3 - and
;              may have one shell in flight normally, or two once
;              the star reaches level 3. if the allowance is
;              already spent the press does nothing.
;   in:   fireown
;   uses: a, x, fireslot, fireallow, firecount, firefree,
;         firedir, firex, firey
; ------------------------------------------------------------
firebullet
        lda endgame           ; nothing you can do to stop it
        beq @notend           ; (NOT @canfire: that name is already
        rts                   ; used further down, and the assembler
@notend ldx fireown           ; silently sent this branch there, past
                               ; the reload and the shell count)
        lda p1cool,x          ; still reloading?
        beq @loaded
        rts
@loaded lda fireown
        asl a
        sta fireslot          ; 0 for player 1, 2 for player 2
        ldx fireown
        lda p1star,x          ; p1star/p2star are adjacent, so the
        cmp #2                ; owner indexes straight into them. two
                               ; shells from level 2, per the manual
        bcc @one
        lda #2
        jmp @haveallow
@one    lda #1
@haveallow
        sta fireallow
        lda #0
        sta firecount
        ldx fireslot
        lda pbactive,x
        beq @n1
        inc firecount
@n1     inx
        lda pbactive,x
        beq @n2
        inc firecount
@n2     lda firecount
        cmp fireallow
        bcc @canfire          ; @no is out of branch range from here
        jmp @no
@canfire
        ldx fireslot
        lda pbactive,x
        beq @got
        inx
@got    stx firefree
        ldx fireown           ; start the reload
        lda p1star,x
        beq @slowload
        lda #firecoolup
        jmp @setcool
@slowload
        lda #firecool
@setcool
        sta p1cool,x
        jsr playfiresound
        lda fireown
        bne @p2
        lda p1facing
        sta firedir
        lda p1x
        sta firex
        lda p1y
        sta firey
        jmp @place
@p2     lda p2facing
        sta firedir
        lda p2x
        sta firex
        lda p2y
        sta firey
@place  ldx firefree
        lda firedir
        sta pbdir,x
        lda #1
        sta pbactive,x
        lda firedir
        cmp #0
        bne @notup
        lda firex             ; muzzle offsets, as before: the shell
        clc                   ; leaves the middle of the leading edge
        adc #8
        sta pbx,x
        lda firey
        sec
        sbc #1
        sta pby,x
        rts
@notup  cmp #1
        bne @notdown
        lda firex
        clc
        adc #8
        sta pbx,x
        lda firey
        clc
        adc #16
        sta pby,x
        rts
@notdown
        cmp #2
        bne @notleft
        lda firex
        sec
        sbc #1
        sta pbx,x
        lda firey
        clc
        adc #8
        sta pby,x
        rts
@notleft
        lda firex
        clc
        adc #16
        sta pbx,x
        lda firey
        clc
        adc #8
        sta pby,x
@no     rts

; ------------------------------------------------------------
; updatebullets   fire on request, then step all four player
;                 shells and resolve what each one hits.
;   uses: a, x, y, pbidx, and everything updatebullet uses
; ------------------------------------------------------------
updatebullets
        lda #$ff              ; defensive - see updateplayers' note
        sta $dc00
        lda p1cool            ; reloads tick down once each frame
        beq @c2
        dec p1cool
@c2     lda p2cool
        beq @cdone
        dec p2cool
@cdone
        lda p1alive
        beq @nf1
        lda p1respawn
        bne @nf1
        lda joy1
        and #16
        bne @nf1              ; bit set = not pressed (active low)
        lda #0
        sta fireown
        jsr firebullet
@nf1    lda p2alive
        beq @nf2
        lda p2respawn
        bne @nf2
        lda joy2
        and #16
        bne @nf2
        lda #1
        sta fireown
        jsr firebullet
@nf2
        ldx #0
@lp     stx pbidx
        lda pbactive,x
        bne @live
        jmp @next
@live   sta bactive
        lda pbx,x
        sta bx
        lda pby,x
        sta by
        lda pbdir,x
        sta bdir
        cpx #2                ; slots 0-1 are player 1's, 2-3 player 2's
        bcc @own1
        lda p2star
        jmp @haves
@own1   lda p1star
@haves  sta bstar             ; the star's effects ride on the shell
        jsr updatebullet
        lda bstar             ; level 1+: step it twice, doubling shell
        beq @stepped          ; speed without touching the step itself
        lda bactive
        beq @stepped
        jsr updatebullet
@stepped
        ldx pbidx
        lda bactive
        sta pbactive,x
        lda bx
        sta pbx,x
        lda by
        sta pby,x
        lda bactive
        bne @stillflying      ; @next is out of branch range now
        jmp @next             ; (a wall or the base already ate it)
@stillflying
        ldx #4                ; a player shell knocks an enemy shell out
@slp    lda moactive,x        ; of the air, as in the original. both are
        beq @snext            ; only 4 pixels, so the test is generous -
        lda mox,x             ; a near miss counts, which is what makes
        sec                    ; it feel like a deflection rather than a
        sbc bx                 ; coincidence
        bcs @sposx
        eor #$ff
        clc
        adc #1
@sposx  cmp #7
        bcs @snext
        lda moy,x
        sec
        sbc by
        bcs @sposy
        eor #$ff
        clc
        adc #1
@sposy  cmp #7
        bcs @snext
        lda #0
        sta moactive,x        ; the enemy shell
        ldy pbidx
        sta pbactive,y        ; and ours
        jmp @next
@snext  inx
        cpx #8
        bne @slp

        lda friendlyfire
        beq @enemies
        ldx pbidx
        cpx #2
        bcc @vs2
        lda p1alive           ; player 2's shell against player 1
        beq @enemies
        lda p1x
        sta pibx
        lda p1y
        sta piby
        jsr pointinbox
        bcc @enemies
        ldx pbidx
        lda #0
        sta pbactive,x
        jsr hittank1
        jmp @next
@vs2    lda p2alive           ; player 1's shell against player 2
        beq @enemies
        lda p2x
        sta pibx
        lda p2y
        sta piby
        jsr pointinbox
        bcc @enemies
        ldx pbidx
        lda #0
        sta pbactive,x
        jsr hittank2
        jmp @next

@enemies
        ldx #0
@elp    lda moactive,x
        beq @enext
        lda mox,x
        sta pibx
        lda moy,x
        sta piby
        jsr pointinbox
        bcc @enext
        ldy pbidx
        lda #0
        sta pbactive,y
        cpy #2                ; slots 0-1 are player 1's, 2-3 player 2's
        bcc @byp1
        lda #1
        jmp @savekiller
@byp1   lda #0
@savekiller
        sta killer
        jsr killenemy         ; x is the enemy index, as it expects
        jmp @next
@enext  inx
        cpx #4
        bne @elp

@next   ldx pbidx
        inx
        cpx #4
        beq @done
        jmp @lp
@done   rts
; ------------------------------------------------------------
; respawnp1 / respawnp2   snap a tank back to its original spawn
;   uses: a
; ------------------------------------------------------------
respawnp1
        lda p1facing       ; travel direction follows the facing
        sta p1travel
        lda p1spawnx
        sta p1x
        lda p1spawny
        sta p1y
        rts
respawnp2
        lda p2facing       ; travel direction follows the facing
        sta p2travel
        lda p2spawnx
        sta p2x
        lda p2spawny
        sta p2y
        rts

; ------------------------------------------------------------
; hittank1 / hittank2   a bullet just hit this tank: lose a
;               life and respawn, or - out of lives - remove it
;               from play and check whether the game just ended.
;   uses: a
; ------------------------------------------------------------
hittank1
        lda p1respawn       ; already blowing up - one death at a time
        beq @alive
        rts
@alive  lda p1shield        ; helmet: soak the hit entirely
        beq @noshield
        rts
@noshield
        lda #0                ; the upgrade dies with the tank
        sta p1star
        lda p1x             ; a burst where the tank stood, the same
        sta cx                 ; one the enemies get - the player used
        lda p1y              ; to vanish and reappear with nothing to
        sta cy                 ; show a life had gone
        jsr tileunder
        jsr spawnexplosion
        jsr playexplosion
        dec p1lives
        jsr marksidebar
        lda d015
        and #%11111110    ; hide the wreck either way
        sta d015
        lda p1lives
        bne @respawn
        lda #0
        sta p1alive
        jsr checkbothout
        rts
@respawn
        lda #deathpause       ; burn for a moment before coming back
        sta p1respawn
        rts

hittank2
        lda p2respawn       ; already blowing up - one death at a time
        beq @alive
        rts
@alive  lda p2shield        ; helmet: soak the hit entirely
        beq @noshield
        rts
@noshield
        lda #0                ; the upgrade dies with the tank
        sta p2star
        lda p2x             ; a burst where the tank stood, the same
        sta cx                 ; one the enemies get - the player used
        lda p2y              ; to vanish and reappear with nothing to
        sta cy                 ; show a life had gone
        jsr tileunder
        jsr spawnexplosion
        jsr playexplosion
        dec p2lives
        jsr marksidebar
        lda d015
        and #%11111101    ; hide the wreck either way
        sta d015
        lda p2lives
        bne @respawn
        lda #0
        sta p2alive
        jsr checkbothout
        rts
@respawn
        lda #deathpause       ; burn for a moment before coming back
        sta p2respawn
        rts

; ------------------------------------------------------------
; checkbothout   both tanks out of lives -> game over
;   uses: a
; ------------------------------------------------------------
checkbothout
        lda duelmode
        bne @duel
        lda p1alive
        ora p2alive
        bne @notover
        jsr triggergameover
@notover
        rts
@duel   lda p1alive           ; a duel ends the moment either side has
        bne @p2check          ; no tanks left - the other player wins
        lda #2
        sta winner
        jsr triggergameover
        rts
@p2check
        lda p2alive
        bne @notover2
        lda #1
        sta winner
        jsr triggergameover
@notover2
        rts

; ------------------------------------------------------------
; startending   ninety-nine stages cleared. the field empties, a
;               siren starts, and a second later a missile comes
;               down on the reactor. the players can still drive
;               about, but they cannot fire, and nothing they do
;               changes where it lands - not even a shovel's
;               armour, which the strike ignores.
;   uses: a, x, y
; ------------------------------------------------------------
startending
        jsr clearobjects      ; every tank and shell gone, all sprites off
        lda #0
        sta stageleft
        sta endtimer
        sta sirdir
        lda #3                ; the first count of the long wait
        sta endsub
        lda #0
        lda #<sirlo
        sta sirfreq
        lda #>sirlo
        sta sirfreq+1
        lda #missiletop
        sta misy
        lda p1alive           ; the players come back on; clearobjects
        beq @nop1             ; switched them off with everything else
        lda d015
        ora #%00000001
        sta d015
@nop1   lda nplayers
        cmp #2
        bne @nop2
        lda p2alive
        beq @nop2
        lda d015
        ora #%00000010
        sta d015
@nop2   lda $d412             ; the siren, on voice 3: a sawtooth held
        and #%11111110        ; at full sustain and swept up and down
        sta $d412
        lda #0
        sta $d413
        lda #$f0
        sta $d414
        lda sirfreq
        sta $d40e
        lda sirfreq+1
        sta $d40f
        lda #$21
        sta $d412
        lda #1
        sta endgame
        rts

; ------------------------------------------------------------
; updateending   once a tick while the missile falls
;   uses: a
; ------------------------------------------------------------
updateending
        lda sirdir            ; the siren wails up and down, two
        bne @down             ; seconds each way
        lda sirfreq
        clc
        adc #sirstep
        sta sirfreq
        lda sirfreq+1
        adc #0
        sta sirfreq+1
        cmp #>sirhi
        bcc @setsir
        lda #1
        sta sirdir
        jmp @setsir
@down   lda sirfreq
        sec
        sbc #sirstep
        sta sirfreq
        lda sirfreq+1
        sbc #0
        sta sirfreq+1
        cmp #>sirlo
        bcs @setsir
        lda #0
        sta sirdir
@setsir lda sirfreq
        sta $d40e
        lda sirfreq+1
        sta $d40f

        lda endtimer          ; fifteen seconds of siren before it
        cmp #launchdelay      ; appears - nothing to see, only the noise
        bcs @falling
        dec endsub            ; endtimer counts in threes while it waits
        beq @count
        rts
@count  lda #3
        sta endsub
        inc endtimer
        lda endtimer          ; the pause ends THIS tick: place the
        cmp #launchdelay      ; missile now, before the interrupt
        bcs @falling          ; switches its sprite on - or it shows
        rts                   ; for a frame wherever sprite 7 last was
@falling
        lda #116              ; over the reactor, centred on it
        sta $d00e
        lda misy
        sta $d00f
        lda #1                ; white
        sta $d02e
        lda #icbmptr
        sta $4400+$3f8+7
        lda $d010
        and #%01111111
        sta $d010
        lda $d01b
        and #%01111111
        sta $d01b
        inc misy
        lda misy
        cmp #missilehit       ; the nose has reached the reactor
        bcc @done
        lda $d412             ; siren off
        and #%11111110
        sta $d412
        lda #0
        sta endgame
        lda #1
        sta nobodywins
        lda #baserow
        sta trow
        lda #basecol
        sta tcol
        jsr destroybase       ; the cloud, and the end
@done   rts

; ------------------------------------------------------------
; triggergameover   end the round: hide every hardware sprite
;                    (0-7) and set gameover. once gameover is
;                    set, the main loop stops calling
;                    updateplayers/updatebullets/updateenemies/
;                    updateenemybullets/buildsprites entirely -
;                    so whatever those sprites happened to be
;                    showing on the very last tick would
;                    otherwise just stay frozen on screen
;                    forever, since nothing ever touches them
;                    again for the rest of the round.
;   uses: a
; ------------------------------------------------------------
triggergameover
        lda #0
        sta d015
        lda #1
        sta gameover
        rts

; ------------------------------------------------------------
; updatebullet   move one bullet 2px, then resolve whatever its
;                leading edge just entered. tank-vs-bullet
;                checks are NOT done here - the caller does its
;                own point-in-box test(s) against whichever
;                targets are relevant to that bullet's owner
;                (see pointinbox), since player bullets and
;                enemy bullets have different target lists.
;   in:   bactive, bx, by, bdir (0=up 1=down 2=left 3=right)
;   out:  bactive (0 if a wall/base consumed it), bx, by
;   uses: a, x, y, trow, tcol
; ------------------------------------------------------------
updatebullet
        lda bactive
        bne @moving
        rts
@moving lda bdir
        cmp #0
        bne @notup
        lda by
        sec
        sbc #2
        sta by
        lda by               ; probe the leading (top) edge
        jsr ytotile
        bcs @up1ok
        jmp @gone
@up1ok  sta trow
        lda bx
        jsr xtotile
        bcs @up2ok
        jmp @gone
@up2ok  sta tcol
        jmp @havetile
@notup  cmp #1
        bne @notdown
        lda by
        clc
        adc #2
        sta by
        lda by
        clc
        adc #3               ; leading (bottom) edge of a ~4px bullet
        jsr ytotile
        bcs @dn1ok
        jmp @gone
@dn1ok  sta trow
        lda bx
        jsr xtotile
        bcs @dn2ok
        jmp @gone
@dn2ok  sta tcol
        jmp @havetile
@notdown
        cmp #2
        bne @notleft
        lda bx
        sec
        sbc #2
        sta bx
        lda bx
        jsr xtotile
        bcs @lf1ok
        jmp @gone
@lf1ok  sta tcol
        lda by
        jsr ytotile
        bcs @lf2ok
        jmp @gone
@lf2ok  sta trow
        jmp @havetile
@notleft
        lda bx
        clc
        adc #2
        sta bx
        lda bx
        clc
        adc #3
        jsr xtotile
        bcs @rt1ok
        jmp @gone
@rt1ok  sta tcol
        lda by
        jsr ytotile
        bcs @rt2ok
        jmp @gone
@rt2ok  sta trow
@havetile
        jsr probepair         ; a = the harder of the two cells the shell
        cmp #2                ; spans; pv1/pv2 hold them individually
        bne @notsteel
        lda bstar             ; steel stands unless the gun is fully
        cmp #3                ; upgraded - armour-piercing is level 3
        bcc @steelstands
        jsr clearpair
        jmp @gone
@steelstands
        jsr clearbrickpair    ; steel stops the shell, but any brick
        jmp @gone             ; beside it still comes down
@notsteel
        cmp #1
        bne @notbrick
        jsr clearbrickpair
        jmp @gone
@notbrick
        cmp #3
        bne @floor
        jsr destroybase
        jmp @gone
@floor  rts                  ; open floor - bullet survives, caller
                              ; checks it against tank hitboxes
@gone   lda #0
        sta bactive
        rts


; ------------------------------------------------------------
; clearbrickpair   a shell knocks out TWO brick cells, not one:
;                  the cell it entered, plus its neighbour on the
;                  side the shell is nearer, measured across the
;                  direction of travel. a tank is two cells wide and
;                  fires from the middle of its barrel, so the pair
;                  it opens is exactly the gap it can drive through -
;                  with single-cell holes you had to line up on a
;                  half-tile that does not exist.
;   in:   trow, tcol = the cell hit; bdir, bx, by
;   uses: a, x, y
;   note: the neighbour is only cleared if it is brick as well, and
;         only if it is on the field - dec'ing tcol at column 0 would
;         wrap to 255 and scribble through whatever follows the row.
; ------------------------------------------------------------
; probepair   a shell is only 4 pixels across but it travels down the
;             middle of a two-cell lane, so it straddles the boundary
;             between them. testing only the single point it occupies
;             meant that once one half of a wall was gone, the shell
;             sailed straight through whatever was left in the other
;             half - a brick on the left survived a shot whose centre
;             happened to sit in the cleared cell on the right.
;
;             this works out both cells the shell spans across its
;             direction of travel - the one its centre is in, and the
;             neighbour it is nearer - reads both, and reports the
;             harder of the two, so the shell reacts to a wall
;             anywhere underneath it.
;   in:   trow, tcol = the cell the shell's centre is in; bdir, bx, by
;   out:  a = max(pv1, pv2): base > steel > brick > floor.
;         pv1 = centre cell, pv2 = neighbour.
;         trow/tcol unchanged; trow2/tcol2 = the neighbour.
;   uses: a, x, y
;   note: at the field edge the neighbour is the cell itself, so
;         nothing wraps - dec'ing tcol at column 0 gives 255 and would
;         read through the following row.
; ------------------------------------------------------------
probepair
        lda trow
        sta trow2
        lda tcol
        sta tcol2
        lda bdir
        cmp #2
        bcs @vert             ; left/right: neighbour is above or below
        lda bx                ; up/down: neighbour is left or right
        sec
        sbc #24
        and #7
        cmp #4
        bcs @right
        lda tcol
        beq @read             ; column 0 - nothing to the left
        dec tcol2
        jmp @read
@right  lda tcol
        cmp #25
        bcs @read
        inc tcol2
        jmp @read
@vert   lda by
        sec
        sbc #50
        and #7
        cmp #4
        bcs @down
        lda trow
        beq @read
        dec trow2
        jmp @read
@down   lda trow
        cmp #24
        bcs @read
        inc trow2
@read   jsr tileat
        sta pv1
        lda trow
        pha
        lda tcol
        pha
        lda trow2
        sta trow
        lda tcol2
        sta tcol
        jsr tileat
        sta pv2
        pla
        sta tcol
        pla
        sta trow
        lda pv1               ; rank by severity, not by raw value: a
        jsr severity           ; damaged brick is 4-7, which would
        sta sev1               ; otherwise outrank steel and the base
        lda pv2
        jsr severity
        cmp sev1
        bcs @done
        lda sev1
@done   rts

; ------------------------------------------------------------
; severity   raw tile value -> 0 floor, 1 brick (whole or damaged),
;            2 steel, 3 base.
; ------------------------------------------------------------
severity
        cmp #armrmask         ; $20-$2f is armour the level placed
        bcc @notarmr
        lda #2
        rts
@notarmr
        cmp #brickmask
        bcc @notbrick2
        lda #1                ; $10-$1f is brick, whole or damaged
        rts
@notbrick2
        cmp #tileriver        ; river, forest and ice are nothing to a
        bcc @plain             ; shell
        cmp #11
        bcs @plain
        lda #0
@plain  rts

; ------------------------------------------------------------
; clearbrickpair   knock out whichever of the two spanned cells are
;                  brick. a tank is two cells wide and fires from the
;                  middle of its barrel, so the gap this opens is
;                  exactly the one it can drive through.
; clearpair        the same for steel - a fully upgraded gun only.
;   in:   pv1/pv2, trow/tcol and trow2/tcol2, all from probepair
;   uses: a, x, y
; ------------------------------------------------------------
; ------------------------------------------------------------
; clearbrickpair   damage whichever of the two spanned cells are
;                  brick. as in the original, one shell only takes
;                  out the HALF facing the shooter - a whole brick
;                  becomes a half brick, and only a second shell
;                  through the same place clears it. a half brick
;                  still blocks, so a wall takes two volleys to open.
;   in:   pv1/pv2 and trow/tcol, trow2/tcol2 from probepair
;   uses: a, x, y
; ------------------------------------------------------------
clearbrickpair
        lda pv1
        jsr severity
        cmp #1
        bne @second
        lda pv1               ; the centre cell
        jsr damagebrick
@second lda pv2
        jsr severity
        cmp #1
        bne @done
        lda trow2
        sta trow
        lda tcol2
        sta tcol
        lda pv2
        jsr damagebrick
@done   rts

; ------------------------------------------------------------
; damagebrick   a = the cell's current value, trow/tcol = the cell.
;               whole brick -> the half away from the shell survives;
;               already damaged -> gone entirely.
;   uses: a, x, y
; ------------------------------------------------------------
damagebrick
        and #15               ; the quarters still standing
        sta bmask
        ldx bdir              ; the shell eats the half facing it, so
        lda keepmask,x        ; what survives is the far half of what
        and bmask             ; was there
        beq @finish           ; nothing left at all
        cmp bmask
        beq @finish           ; that half was already gone - a shell
                               ; through the same hole takes the rest,
                               ; rather than leaving the cell untouched
                               ; and the shell stopped on nothing
        ora #brickmask
        jsr setfieldcell
        jsr drawfieldcell
        rts
@finish jsr clearfieldcell
        jsr clearcell
        rts

; quarters surviving a shell from each direction. bit0 tl, bit1 tr,
; bit2 bl, bit3 br. travelling up the shell eats the bottom pair, so
; the top pair (bits 0,1 = 3) is what is left.
keepmask byte 3,12,5,10       ; up, down, left, right
; quarter masks for the halves a level can place: top, bottom,
; left, right remaining - the same four the construction mode offers.

; glyph for each mask of surviving quarters. only the reachable
; masks matter - whole, the four halves and the four corners - but
; the table is filled out so a stray value still draws something.
; the note table, C1 to B6 - 72 notes, for the anthem and the wave
; ditty. note n plays entry n-1, so that 0 can mean a rest.
; the frequencies are PAL: on an ntsc machine every note sounds about
; 3.6% sharp - a bit over half a semitone. audible to a musician,
; unremarkable to everyone else, and the alternative is carrying two
; tables or multiplying at runtime.
notefreqlo
        byte 45,78,113,150,190,231,20,66,116,169,224,27
        byte 90,156,226,45,123,207,39,133,232,81,193,55
        byte 180,56,196,89,247,157,78,10,208,162,129,109
        byte 103,112,137,178,237,59,156,19,160,69,2,218
        byte 206,224,17,100,218,118,57,38,64,137,4,180
        byte 156,192,35,200,180,235,114,76,128,18,8,104
notefreqhi
        byte 2,2,2,2,2,2,3,3,3,3,3,4
        byte 4,4,4,5,5,5,6,6,6,7,7,8
        byte 8,9,9,10,10,11,12,13,13,14,15,16
        byte 17,18,19,20,21,23,24,26,27,29,31,32
        byte 34,36,39,41,43,46,49,52,55,58,62,65
        byte 69,73,78,82,87,92,98,104,110,117,124,131

attrname
        byte 32,32,32,32,12,9,7,8,20,32,32,32
        byte 1,18,13,15,21,18,5,4,32,3,1,18
        byte 32,18,1,16,9,4,32,6,9,18,5,32
        byte 32,32,32,32,8,5,1,22,25,32,32,32
        byte 32,32,32,32,19,20,1,18,32,32,32,32
        byte 4,18,15,14,5,32,19,20,18,9,11,5
        byte 32,32,32,8,5,12,13,5,20,32,32,32
        byte 32,32,32,19,8,15,22,5,12,32,32,32
        byte 32,5,24,20,18,1,32,20,1,14,11,32
        byte 32,32,32,32,23,1,20,3,8,32,32,32
        byte 2,15,14,21,19,32,20,1,18,7,5,20   ; the drone
attrexpl
        byte 15,14,5,32,19,8,15,20,32,32,32,49,48,48,32,16,15,9,14,20,19,32
        byte 13,15,22,5,19,32,6,1,19,20,32,50,48,48,32,16,15,9,14,20,19,32
        byte 32,32,6,1,19,20,32,19,8,5,12,12,19,32,51,48,48,32,16,20,19,32
        byte 6,15,21,18,32,19,8,15,20,19,32,52,48,48,32,16,15,9,14,20,19,32
        byte 32,32,21,16,7,18,1,4,5,19,32,25,15,21,18,32,7,21,14,32,32,32
        byte 32,20,1,11,5,19,32,15,21,20,32,5,22,5,18,25,32,20,1,14,11,32
        byte 32,32,19,8,9,5,12,4,19,32,25,15,21,32,1,32,23,8,9,12,5,32
        byte 32,32,1,18,13,15,21,18,19,32,25,15,21,18,32,2,1,19,5,32,32,32
        byte 32,32,32,32,15,14,5,32,5,24,20,18,1,32,12,9,6,5,32,32,32,32
        byte 32,32,6,18,5,5,26,5,19,32,20,8,5,32,5,14,5,13,25,32,32,32
        byte 49,48,48,48,32,16,20,19,32,38,32,5,24,20,18,1,32,12,9,6,5,32   ; the drone
attrhead
        byte 5,14,5,13,25,32,20,1,14,11,19,32
        byte 2,15,14,21,19,32,9,20,5,13,19,32
        byte 5,14,5,13,25,32,4,18,15,14,5,32   ; "ENEMY DRONE"
attrfoot
        byte 6,9,18,5,32,20,15,32,18,5,20,21,18,14

attrglyph byte 0,0,0,0,pwstar,pwdrone,pwhelm,pwshov,pwtank,pwwatch

brickglyph
        byte 96,138,139,134,140,136,96,96
        byte 141,96,137,96,135,96,96,96
; armour halves the level can place. damage never produces these, so
; only whole and the four halves are reachable.
armrglyph
        byte 97,97,97,145,97,147,97,97
        byte 97,97,148,97,146,97,97,97

; ------------------------------------------------------------
; clearpair   steel, for a twice-starred gun: no half measures.
; ------------------------------------------------------------
clearpair
        lda pv1               ; by severity, not raw value: the shovel's
        jsr severity          ; shield writes 2, but a level places
        cmp #2                ; armour as $20-$2f, and a raw compare
        bne @second           ; against 2 missed all of it - a fully
        jsr clearfieldcell    ; starred gun could not break level armour
        jsr clearcell
@second lda pv2
        jsr severity
        cmp #2
        bne @done
        lda trow2
        sta trow
        lda tcol2
        sta tcol
        jsr clearfieldcell
        jsr clearcell
@done   rts
; ------------------------------------------------------------
; pointinbox   is (bx,by) within a 16x16 box at (pibx,piby)?
;   out:  carry set = yes, clear = no
;   uses: a
; ------------------------------------------------------------
pointinbox
        lda bx                ; the shell is not a point: its 4-pixel
        sec                    ; block spans bx-2..bx+1, so it overlaps a
        sbc pibx               ; 16-pixel tank box for bx anywhere from
        clc                    ; pibx-1 to pibx+17 - nineteen positions,
        adc #1                 ; not sixteen. testing the centre alone
        cmp #19                ; meant a tank misaligned by one character
        bcs @no                ; block was missed even though the shell
        lda by                 ; visibly clipped it by a couple of pixels.
        sec
        sbc piby
        clc
        adc #1
        cmp #19
        bcs @no
        sec
        rts
@no     clc
        rts

; ------------------------------------------------------------
; destroybase   clear all 4 base cells to floor, end the game.
;   uses: a, trow, tcol (clobbered), and clearfieldcell/clearcell
; ------------------------------------------------------------
destroybase
        lda nobodywins        ; the missile: no explosion. what follows
        bne @silent           ; is a minute's silence, from the first frame
        jsr playexplosion
@silent
        lda duelmode          ; in a duel there are two of them, and the
        beq @single           ; row the shell struck says which
        lda trow
        cmp #3
        bcs @p1base
        lda #duelbaserow      ; the top one
        sta wreckrow
        lda #0
        lda #3                ; a reactor went up: nobody wins. only
        sta winner            ; outlasting the other player counts as a
        jmp @bothdone         ; win (of sorts) - see drawgameover
@p1base lda #baserow          ; the bottom one
        sta wreckrow
        lda #0
        lda #3
        sta winner
        jmp @bothdone
@single lda #baserow          ; only one base in a normal game
        sta wreckrow
        lda #0
@bothdone
        jsr triggergameover
        lda wreckrow          ; clear the four cells of whichever base
        sta trow              ; was hit - this used to be hardcoded to
        lda #basecol          ; the bottom one, so shooting the top base
        sta tcol              ; blew a hole in the bottom player's
        jsr clearfieldcell    ; instead
        jsr clearcell
        inc tcol
        jsr clearfieldcell
        jsr clearcell
        inc trow
        lda #basecol
        sta tcol
        jsr clearfieldcell
        jsr clearcell
        inc tcol
        jsr clearfieldcell
        jsr clearcell
        lda wreckrow          ; and the cloud goes there too
        sta g2row
        lda #basecol
        sta g2col
        lda #wreckchr
        sta gbase
        lda #11               ; dark grey
        sta gcol
        jsr draw2x2
        lda #1
        sta wreckshown
        rts
; ------------------------------------------------------------
; clearfieldcell   set field[trow*26+tcol] = 0 (floor)
;   in:   trow, tcol
;   uses: a, x, y, lvlptr
; ------------------------------------------------------------
clearfieldcell
        ldx trow
        lda #<field
        clc
        adc fieldrowlo,x
        sta lvlptr
        lda #>field
        adc fieldrowhi,x
        sta lvlptr+1
        ldy tcol
        lda #0
        sta (lvlptr),y
        rts

; ------------------------------------------------------------
; clearcell   redraw screen cell (trow,tcol) as floor
;   in:   trow, tcol
;   uses: a, x, y, scrptr, colptr
; ------------------------------------------------------------
clearcell
        ldx trow
        lda #<$4400
        clc
        adc screenrowlo,x
        sta scrptr
        lda #>$4400
        adc screenrowhi,x
        sta scrptr+1
        lda #<$d800
        clc
        adc screenrowlo,x
        sta colptr
        lda #>$d800
        adc screenrowhi,x
        sta colptr+1
        ldy tcol
        lda #32
        sta (scrptr),y
        lda #0
        sta (colptr),y
        rts


; ==============================================================
; STAGE 5: enemy tanks and AI
; ==============================================================

; ------------------------------------------------------------
; startstage   begin a stage: 20 enemy tanks to get through, but
;              only 4 on the field at a time - the rest trickle
;              in from three fixed entry points along the top as
;              slots free up (see trickleenemies). this spawn
;              economy, not the per-tank ai, is what makes the
;              original feel relentless: killing one does not
;              empty the field, it just lets the next one in, so
;              pressure is continuous until the stage is done.
;              the previous version put all 4 out at once and
;              waited for every one to die before refilling,
;              which let the field empty and the tension reset.
;              level data may still carry enemy-spawn markers
;              (value 6); they stay legal in the format but no
;              longer place anything, since entry points are
;              fixed by the game rather than by the level.
;   uses: a, x
; ------------------------------------------------------------
spawnenemies
        lda duelmode          ; a duel is two players and nothing else
        beq @normal
        lda #0
        sta stageleft
        jmp @clearall
@normal lda #enemiesperstage
        sta stageleft
@clearall
        lda #0
        sta nextslot
        sta spawntimer
        sta spawncount
        sta hunterslot        ; a fresh stage picks its own runner
        sta huntertimer
        sta staractive        ; a marker left pulsing when the last game
        sta startimer         ; ended would hatch its tank into the new
        sta pendslot          ; one - at whatever position it held then,
                               ; which is how an enemy appeared sitting
                               ; on a player's spawn
        ldx #0
@clp    lda #0
        sta moactive,x
        inx
        cpx #4
        bne @clp
        ldx #0
@blp    lda #0
        sta moactive+4,x
        lda #4               ; purple, as the players' shells are: all
        sta mocol+4,x        ; shells look the same now
        lda #bulletptr             ; bulletspr block - without this every
        sta moptr+4,x        ; enemy bullet points at $0000 (garbage)
        inx
        cpx #4
        bne @blp
        rts

; ------------------------------------------------------------
; hatchenemy   the marker has finished pulsing: let the tank that
;              trickleenemies configured actually appear.
;   uses: a, x
; ------------------------------------------------------------
hatchenemy
        ldx pendslot
        lda #1
        sta moactive,x
        rts

; ------------------------------------------------------------
; pickfarslot   set nextslot to whichever entry point is furthest
;               from the nearest living player. the original never
;               drops a tank next to you, which stops both nasty
;               surprises and the reverse - camping an entry and
;               shooting them as they appear.
;   uses: a, x, y
; ------------------------------------------------------------
pickfarslot
        lda #0
        sta pfbest
        lda #0
        sta pfbestd
        ldx #0
@lp     stx pftmp
        lda slotx,x           ; distance to player 1, x axis only:
        sec                   ; the entries are all on the top row, so
        sbc p1x               ; horizontal separation is what matters
        bcs @p1pos
        eor #$ff
        clc
        adc #1
@p1pos  sta pfd
        lda p1alive
        bne @havep1
        lda #255              ; a dead player is infinitely far away
        sta pfd
@havep1 lda p2alive
        beq @cmp
        ldx pftmp
        lda slotx,x
        sec
        sbc p2x
        bcs @p2pos
        eor #$ff
        clc
        adc #1
@p2pos  cmp pfd               ; keep whichever player is nearer
        bcs @cmp
        sta pfd
@cmp    lda pfd
        cmp pfbestd
        bcc @next
        sta pfbestd
        ldx pftmp
        stx pfbest
@next   ldx pftmp
        inx
        cpx #3
        bne @lp
        lda pfbest
        sta nextslot
        rts

; ------------------------------------------------------------
; startspawnstar / updatespawnstar   a pulsing marker stands on the
;   entry point for a moment before the tank appears, so an arrival
;   is announced rather than sprung. the tank is held in
;   pendslot/pendx/pendy meanwhile.
;   uses: a, x, y
; ------------------------------------------------------------
startspawnstar
        lda #spawnticks
        sta startimer
        lda #1
        sta staractive
        rts

updatespawnstar
        lda staractive
        bne @on
        rts
@on     lda startimer
        beq @hatch
        dec startimer
        lda starrow           ; pulse between the two frames
        sta g2row
        lda starcol
        sta g2col
        lda tick
        and #8
        beq @f1
        lda #spawnchr
        jmp @draw
@f1     lda #spawnchr+1
@draw   sta gbase
        lda #1
        sta gcol
        jsr draw2x2single
        rts
@hatch  ldx pendslot          ; the spot was clear when the marker went
        lda mox,x             ; up, but that was over a second ago and
        sta chkx              ; something may have driven onto it since.
        lda moy,x             ; check again before letting the tank in,
        sta chky              ; or it materialises inside whatever is
        jsr posclear          ; standing there
        bcs @letin
        lda #spawnretry       ; still occupied - keep pulsing and try
        sta startimer         ; again shortly
        rts
@letin  lda #0
        sta staractive
        lda starrow           ; wipe the marker, then let the tank in
        sta g2row
        lda starcol
        sta g2col
        jsr restore2x2
        jsr hatchenemy
        rts

; ------------------------------------------------------------
; draw2x2single   the marker is one glyph tiled over the 2x2 cell
;                 block, not four different ones.
; ------------------------------------------------------------
draw2x2single
        lda gcol
        sta pcol
        lda gbase
        sta pchar
        lda g2row
        sta trow
        lda g2col
        sta tcol
        jsr putchar
        inc tcol
        jsr putchar
        inc trow
        lda g2col
        sta tcol
        jsr putchar
        inc tcol
        jsr putchar
        rts

; ------------------------------------------------------------
; buildspawnlist   expand this stage's formation into the order the
;                  twenty tanks actually arrive in. taken round
;                  robin rather than in blocks, so a stage does not
;                  send eight light tanks and then eight heavies.
;
;                  every tank is promoted one grade per loop of the
;                  35 stages, capping at heavy.
;   uses: a, x, y
; ------------------------------------------------------------
buildspawnlist
        lda wave              ; which stage of the loop, and which loop
        sec
        sbc #1
        ldy #0
@divlp  cmp #35
        bcc @havediv
        sec
        sbc #35
        iny
        jmp @divlp
@havediv
        sty loopno
        asl a                 ; stage index * 4 = offset into stagemix
        asl a
        tax
        ldy #0                ; copy this stage's four counts
@cplp   lda stagemix,x
        sta mixleft,y
        inx
        iny
        cpy #4
        bne @cplp

        ldx #0                ; x = which type we are offering. it has
        ldy #0                ; to be x, not y: there is no dec abs,y
@fill   cpy #enemiesperstage  ; y = how many placed so far
        beq @done
        lda mixleft,x
        beq @nexttype
        dec mixleft,x
        txa                   ; promote by the loop number
        clc
        adc loopno
        cmp #4
        bcc @capped
        lda #3
@capped sta spawnlist,y
        iny
@nexttype
        inx
        cpx #4
        bne @fill
        ldx #0
        jmp @fill
@done   rts

; ------------------------------------------------------------
; rotatehunter   pick which enemy is making for the base. it keeps
;                the job for a spell, then hands over - and hands
;                over at once if it dies. the others still drift
;                toward the base a quarter as often, so they spread
;                across the approach instead of queueing behind the
;                runner.
;   uses: a, x
; ------------------------------------------------------------
rotatehunter
        ldx hunterslot        ; has the current one gone?
        lda moactive,x
        beq @next
        lda huntertimer       ; no - has its turn run out?
        beq @next
        dec huntertimer
        rts
@next   ldx hunterslot        ; hand on to the next tank that exists
        ldy #0
@lp     inx
        cpx #4
        bcc @try
        ldx #0
@try    lda moactive,x
        bne @found
        iny
        cpy #4
        bne @lp
@found  stx hunterslot
        lda #hunterturn
        sta huntertimer
        rts

; ------------------------------------------------------------
; trickleenemies   called once per tick: if the stage still has
;                  tanks to send and a field slot is free, bring
;                  one in at the next entry point that is not
;                  occupied. entry points are taken in turn
;                  (left, centre, right), skipping any with a
;                  tank or player standing on it, so tanks never
;                  materialise on top of each other - the whole
;                  reason the old epending/checkpendingspawns
;                  retry existed. spawntimer paces arrivals so a
;                  cleared field refills over a second or so
;                  rather than instantly.
;   uses: a, x, y, chkx, chky, and everything posclear uses
; ------------------------------------------------------------
trickleenemies
        lda stageleft
        bne @have
        rts
@have   lda staractive        ; one arrival announced at a time
        beq @nostar
        rts
@nostar lda spawntimer
        beq @ready
        dec spawntimer
        rts
@ready  lda wave              ; 2 tanks at once on wave 1, 3 on wave 2,
        cmp #3                ; the full 4 from wave 3 - the single
        bcc @few              ; biggest lever on how frantic it feels
        lda #4
        jmp @havecap
@few    clc
        adc #1
@havecap
        sta fieldcap
        ldx #0
@findlp cpx fieldcap
        bcs @nospawn
        lda moactive,x
        beq @gotslot
        inx
        cpx #4
        bne @findlp
@nospawn
        rts                   ; this wave's allowance is already out
@gotslot
        stx freeslot
        jsr pickfarslot       ; never drop a tank into the player's lap
        lda #3
        sta trys
@trylp  ldx nextslot
        lda slotx,x
        sta chkx
        lda sloty,x
        sta chky
        jsr posclear
        bcs @place
        jsr advslot
        dec trys
        bne @trylp
        rts                   ; every entry point blocked - next tick
@place  ldx nextslot
        lda slotx,x
        sta spx
        lda sloty,x
        sta spy
        jsr advslot
        lda spx               ; announce the arrival first: the marker
        sec                    ; pulses on the spot for a moment and
        sbc #24                ; hatchenemy puts the tank there when it
        lsr a                  ; expires
        lsr a
        lsr a
        sta starcol
        lda spy
        sec
        sbc #50
        lsr a
        lsr a
        lsr a
        sta starrow
        jsr startspawnstar
        ldx freeslot
        stx pendslot
        lda spx
        sta mox,x
        lda spy
        sta moy,x
        lda #0                ; NOT active yet - the marker is showing
        sta moactive,x
        lda #1
        sta modir,x           ; face down - entry points are up top
        lda #tankptr+2        ; facing down (1) * 2, tread phase 0
        sta moptr,x
        lda #0
        sta moanim,x
        sta mostep,x
        lda spawncount        ; the next tank of this stage's formation
        tay
        lda spawnlist,y
        sta etype,x
        tay                   ; the four types of the manual:
        lda typehp,y          ;   0 light        1 hit    100
        sta ehp,x             ;   1 armored car  1 hit    200  (fast)
        lda typecol,y         ;   2 rapid-fire   1 hit    300  (fast shells)
        sta mocol,x           ;   3 heavy        4 hits   400
        lda #0
        sta eforcerand,x
        sta ehold,x           ; a new tank owes nothing to the last one
        lda basemovetimer
        sta emovetimer,x
        lda basefiretimer
        sta efiretimer,x
        inc spawncount
        lda spawncount        ; the 4th, 11th and 18th tank of the 20
        cmp #4                ; carries a power-up and flashes for it
        beq @bonus
        cmp #11
        beq @bonus
        cmp #18
        bne @nobonus
@bonus  ldx freeslot
        lda #1
        sta mobonus,x
@nobonus
        dec stageleft
        lda #spawndelay
        sta spawntimer
        jsr marksidebar
        rts

; ------------------------------------------------------------
; advslot   step nextslot on to the following entry point,
;           wrapping 2 -> 0.
;   uses: a
; ------------------------------------------------------------
advslot lda nextslot
        clc
        adc #1
        cmp #3
        bcc @ok
        lda #0
@ok     sta nextslot
        rts

; ------------------------------------------------------------
; posclear   is the 16x16 box at (chkx,chky) free of every tank
;            currently on the field - both players and all
;            active enemies?
;   out:  carry set = clear, carry clear = occupied
;   uses: a, y, chkx2, chky2
; ------------------------------------------------------------
posclear
        lda p1alive
        beq @p2
        lda p1x
        sta chkx2
        lda p1y
        sta chky2
        jsr boxesoverlap
        bcs @no
@p2     lda p2alive
        beq @en
        lda p2x
        sta chkx2
        lda p2y
        sta chky2
        jsr boxesoverlap
        bcs @no
@en     ldy #0
@elp    lda moactive,y
        beq @enext
        lda mox,y
        sta chkx2
        lda moy,y
        sta chky2
        jsr boxesoverlap      ; uses a only - y survives the call
        bcs @no
@enext  iny
        cpy #4
        bne @elp
        sec
        rts
@no     clc
        rts

; ------------------------------------------------------------
; spawnfree   is player x's spawn point clear to reappear on?
;             checked against every active enemy and against the
;             OTHER player if they are on the field. not posclear:
;             that counts player 1 too, and during player 1's own
;             respawn that would test the spot against itself.
;   in:   x = 0 for player 1, 1 for player 2 (already placed)
;   out:  carry set = clear
;   uses: a, y, chkx, chky, chkx2, chky2
; ------------------------------------------------------------
spawnfree
        cpx #0
        bne @isp2
        lda p1x
        sta chkx
        lda p1y
        sta chky
        lda p2alive           ; the other player, if actually present
        beq @en
        lda p2respawn
        bne @en
        lda p2x
        sta chkx2
        lda p2y
        sta chky2
        jsr boxesoverlap
        bcs @no
        jmp @en
@isp2   lda p2x
        sta chkx
        lda p2y
        sta chky
        lda p1alive
        beq @en
        lda p1respawn
        bne @en
        lda p1x
        sta chkx2
        lda p1y
        sta chky2
        jsr boxesoverlap
        bcs @no
@en     ldy #0
@lp     lda moactive,y
        beq @next
        lda mox,y
        sta chkx2
        lda moy,y
        sta chky2
        jsr boxesoverlap      ; uses a only - y survives the call
        bcs @no
@next   iny
        cpy #4
        bne @lp
        sec
        rts
@no     clc
        rts

; ------------------------------------------------------------
; boxesoverlap   do two 16x16 boxes at (chkx,chky) and
;                (chkx2,chky2) overlap?
;   out:  carry set = overlap
;   uses: a
; ------------------------------------------------------------
boxesoverlap
        lda chkx
        clc
        adc #16
        cmp chkx2
        bcc @no
        beq @no
        lda chkx2
        clc
        adc #16
        cmp chkx
        bcc @no
        beq @no
        lda chky
        clc
        adc #16
        cmp chky2
        bcc @no
        beq @no
        lda chky2
        clc
        adc #16
        cmp chky
        bcc @no
        beq @no
        sec
        rts
@no     clc
        rts

; ------------------------------------------------------------
; brickahead   is the tile directly in front of enemy x a brick?
;              used when a tank is wedged: in the original,
;              enemies chew their own routes through brick rather
;              than milling about in the open, which is most of
;              what makes them feel like they are coming for the
;              base. blocked by steel or the field edge it just
;              turns away instead.
;   in:   x = enemy index (0-3)
;   out:  carry set = brick ahead, clear = anything else
;   uses: a, trow, tcol, brtmpx (x is preserved - tileat eats it)
; ------------------------------------------------------------
brickahead
        stx brtmpx
        lda modir,x
        cmp #0
        bne @nd
        lda moy,x
        sec
        sbc #1
        jsr ytotile
        bcc @no
        sta trow
        lda mox,x
        jsr xtotile
        bcc @no
        sta tcol
        jmp @probe
@nd     cmp #1
        bne @nl
        lda moy,x
        clc
        adc #16
        jsr ytotile
        bcc @no
        sta trow
        lda mox,x
        jsr xtotile
        bcc @no
        sta tcol
        jmp @probe
@nl     cmp #2
        bne @nr
        lda mox,x
        sec
        sbc #1
        jsr xtotile
        bcc @no
        sta tcol
        lda moy,x
        jsr ytotile
        bcc @no
        sta trow
        jmp @probe
@nr     lda mox,x
        clc
        adc #16
        jsr xtotile
        bcc @no
        sta tcol
        lda moy,x
        jsr ytotile
        bcc @no
        sta trow
@probe  jsr tileat
        jsr severity          ; a brick it has already half-destroyed is
        ldx brtmpx            ; still a brick worth shooting - without
        cmp #1                ; this the tank turns away from a wall it
        bne @no2              ; is one shell from opening
        sec
        rts
@no2    clc
        rts
@no     ldx brtmpx
        clc
        rts

; ------------------------------------------------------------
; updateenemies   ai + movement for each active enemy tank.
;
;   this is an original design, not derived from any existing
;   game's code or data - the brief was "each type should feel
;   different, and all of them are ultimately trying to reach
;   the base." every emovetimer ticks, an enemy re-evaluates
;   its direction: computebasepref works out which of the 4
;   directions would move it one step closer to the base
;   (horizontal correction takes priority over vertical - an
;   arbitrary but consistent choice, giving paths a dog-legged,
;   deliberate look rather than a diagonal drift), then a
;   per-type coin flip (biasthresh) decides whether it actually
;   takes that direction or picks a fully random one instead.
;   type also scales how often it reconsiders and how often it
;   fires, via basemovetimer/basefiretimer (which themselves
;   tighten every wave - see newwave):
;     basic    - 40% biased toward the base, average cadence.
;                meanders; not very committed to the goal.
;     fast     - 70% biased, re-evaluates direction and fires
;                twice as often. beelines for the base and is
;                the main thing that punishes standing still.
;     armored  - 55% biased, but re-evaluates half as often and
;                fires half as often. slow and tanky, but keeps
;                grinding toward the base once it picks a line.
;   the direction, once chosen, is committed to the exact same
;   movetank/checkup../checkright pipeline the players use, fed
;   a synthesised "joystick" byte instead of real input.
;   buildotherlist_enemy lists both players and every other
;   active enemy before each move, so tanks now genuinely block
;   each other - they used to be able to drive straight through
;   one another, a known gap from when this stage was written.
;   uses: a, x, y, and everything movetank/rand256/
;         computebasepref/buildotherlist_enemy use
; ------------------------------------------------------------
updateenemies
        lda freezetimer       ; the watch: tanks stop dead, but their
        beq @notfrozen        ; bullets already in flight carry on
        rts
@notfrozen
        jsr trickleenemies
        ldx #0
@lp     lda moactive,x
        bne @active
        jmp @next
@active lda ehold,x           ; the reversal hold runs down every tick
        beq @nohold
        dec ehold,x
@nohold dec emovetimer,x
        beq @repick
        jmp @keepdir
@repick lda eforcerand,x       ; wedged last tick? then pick at random
        beq @normalpick        ; rather than re-deriving the same
        lda #0                 ; base-ward direction that just failed -
        sta eforcerand,x       ; otherwise a tank in a corner can keep
        lda #1                 ; choosing the wall it is already against.
        sta eforced            ; (a wedged tank may turn any way at all)
        jmp @userandom
@normalpick
        lda #0
        sta eforced
        jsr computebasepref    ; sets prefdir
        jsr rand256
        ldy etype,x
        cpx hunterslot        ; one tank at a time presses for the base;
        beq @isrunner         ; the others seek it half as often, so they
        lsr a                 ; spread across the approach rather than
@isrunner                      ; filing down one lane behind the runner.
        cmp biasthresh,y      ; a quarter was tried and left the base
                               ; barely threatened at all.
        bcs @userandom
        ldy wave              ; early waves head for the base far less
        cpy #4                ; often, so the first screens are enemies
        bcs @fullbias         ; to fight rather than a countdown to
        jsr rand256           ; losing the eagle. from wave 4 the full
        cpy #1                ; type bias applies.
        beq @quarter
        cmp #128
        bcs @userandom        ; waves 2-3: half the time, wander instead
        jmp @fullbias
@quarter
        cmp #64
        bcs @userandom        ; wave 1: base-seek only a quarter as often
@fullbias
        lda prefdir           ; take the base-ward direction if it is
        jsr candir            ; open...
        bcs @havedir
        lda prefalt           ; ...otherwise the other base-ward one...
        cmp #255
        beq @userandom
        jsr candir
        bcs @havedir
        jmp @userandom        ; ...and only then give up and wander
@userandom
        jsr rand256
        and #3
                               ; NOTE: an anti-reversal rule was tried
                               ; here and reverted. it cut reversals from
                               ; 56% of direction changes to 31%, and the
                               ; tanks looked far more purposeful - but
                               ; backtracking IS how a wandering tank
                               ; finds a bridge it has overshot. stage 8
                               ; went from reaching the base in a median
                               ; 20 seconds to not reaching it at all in
                               ; three of five runs. the dithering is the
                               ; navigation. what is here now is a TIMED
                               ; hold, not a ban: no straight reversal for
                               ; reversehold ticks after a turn, and never
                               ; for a wedged tank. at 40 ticks stage 8
                               ; failed again (one run in five); at 20 it
                               ; cut the quick back-and-forth to a third,
                               ; and stages 8 12 20 27 31 33 35 all still
                               ; reached the base in every run.
@havedir
        sta ewant
        lda eforced
        bne @turnok
        lda ehold,x
        beq @turnok
        lda modir,x           ; a straight reversal, too soon after the
        eor #1                ; last turn? then carry on as it is
        cmp ewant
        bne @turnok
        lda modir,x
        jmp @setdir
@turnok lda ewant
        cmp modir,x
        beq @setdir           ; no change, so no new hold
        lda #reversehold
        sta ehold,x
        lda ewant
@setdir sta modir,x
        lda basemovetimer      ; type-scaled cadence: fast reconsiders
        ldy etype,x            ; twice as often, armored half as often
        cpy #1
        bne @notfastcadence
        lsr a                 ; armored car: high-speed movement
        jmp @havecadence
@notfastcadence
        cpy #3
        bne @havecadence
        asl a                 ; heavy: slow, but takes four hits
@havecadence
        sta emovetimer,x
@keepdir
        lda #%11101111        ; all directions + fire released
        ldy modir,x
        cpy #0
        bne @notup2
        and #%11111110
        jmp @havejoy
@notup2 cpy #1
        bne @notdown2
        and #%11111101
        jmp @havejoy
@notdown2
        cpy #2
        bne @notleft2
        and #%11111011
        jmp @havejoy
@notleft2
        and #%11110111
@havejoy
        sta cjoy
        lda mox,x
        sta cx
        lda moy,x
        sta cy
        lda modir,x
        sta cfacing
        stx selfidx            ; buildotherlist_enemy excludes this one
        jsr buildotherlist_enemy
        ldx selfidx            ; restore - buildotherlist_enemy clobbers x
        stx etmpx              ; movetank's callees also clobber x - save it
        lda mox,x
        sta prevmx              ; remember where we started, to detect
        lda moy,x               ; a blocked (did-nothing) move below
        sta prevmy
        lda etype,x           ; the armoured car runs at the full rate;
        cmp #1                ; everything else sits out one tick in
        beq @fullspeed        ; four, which is what makes it the fast one
        lda movephase
        and #movemask
        cmp #movemask
        bne @fullspeed
        jmp @notstuck         ; sitting this one out - straight to the
@fullspeed                     ; AI and firing, skipping the move and
        lda epend,x            ; the did-it-move test that follows it
        sta cpend
        lda eslide,x
        sta cslide
        lda etravel,x
        sta ctravel
        lda #0                ; enemies get NO grace period. it exists so
        sta cturn              ; a player who presses a little early still
                                ; makes the corner, and it is cancelled by
                                ; letting go - but the AI never lets go, so
                                ; for an enemy it never expired and they
                                ; slid sideways along walls indefinitely.
                                ; a blocked enemy turns to face and stops;
                                ; its own timer picks a new direction.
        jsr movetank
        ldx etmpx
        lda cpend
        sta epend,x
        lda cslide
        sta eslide,x
        lda ctravel
        sta etravel,x
        lda cturn
        lda cx
        sta mox,x
        lda cy
        sta moy,x
        lda cx
        cmp prevmx
        bne @didmove
        lda cy
        cmp prevmy
        beq @stuck
@didmove
        inc mostep,x          ; tracks advance a link every 4 pixels
        lda mostep,x
        and #3
        bne @notstuck
        lda moanim,x
        eor #1
        sta moanim,x
        jmp @notstuck
@stuck  lda #1                  ; blocked (by a wall or another tank) -
        sta emovetimer,x
        sta eforcerand,x        ; and make that next choice a random one        ; reconsider direction on the NEXT tick.
                                 ; this must be 1, not 0: the tick
                                 ; begins with "dec emovetimer,x" and
                                 ; decrementing 0 wraps to 255, which is
                                 ; non-zero, so the bne below skips the
                                 ; reconsideration and the tank keeps
                                 ; the very direction that is blocked.
                                 ; it then wedges again, sets 0 again,
                                 ; and never picks a new direction -
                                 ; measured at 99% of ticks stationary,
                                 ; with tanks frozen for 79 seconds.
                                 ; 1 decrements to 0 and falls through
                                 ; into the direction choice as intended.
        jsr brickahead          ; wedged against brick? shoot through it
        bcc @notstuck            ; rather than turning away - this is what
        lda moactive+4,x         ; makes enemies carve their own routes
        bne @notstuck            ; toward the base instead of milling in
        jsr spawnenemybullet     ; the open. one bullet per tank already
        ldx etmpx                ; caps the rate; resetting the cadence
        lda basefiretimer        ; below keeps a tank nose-to-brick from
        sta efiretimer,x         ; firing every time its timer frees up.
@notstuck
        lda modir,x           ; pointer = tankptr + facing*2 + phase
        asl a
        clc
        adc moanim,x
        clc
        adc #tankptr
        sta moptr,x
        lda ecool,x           ; the reload ticks down with everything
        beq @nocool           ; else
        dec ecool,x
@nocool dec efiretimer,x
        bne @next
        lda moactive+4,x
        bne @resettimer       ; this enemy's bullet slot is already busy
        jsr spawnenemybullet
@resettimer
        lda basefiretimer      ; type-scaled: fast fires twice as
        ldy etype,x            ; often, armored half as often
        cpy #1
        bne @notfastfire
        lsr a
        jmp @havefirecd
@notfastfire
        cpy #2
        bne @havefirecd
        asl a
@havefirecd
        sta efiretimer,x
@next   inx
        cpx #4
        beq @loopdone
        jmp @lp
@loopdone
        rts

; ------------------------------------------------------------
; spawnenemybullet   fire from enemy x's tank in its current
;                    facing, into that enemy's own bullet slot
;                    (mob index x+4 - the fixed pairing means no
;                    ownership tracking is needed).
;   in:   x = enemy index (0-3)
;   uses: a
; ------------------------------------------------------------
spawnenemybullet
        lda ecool,x           ; still reloading? enemies had no reload at
        beq @loaded           ; all: the wedged-against-brick path fires
        rts                   ; without consulting efiretimer, and
@loaded lda ecooltab          ; point-blank the shell dies the same tick
        ldy etype,x           ; cleared brick about four times faster
        lda ecooltab,y        ; than the player can
        sta ecool,x
        jsr playfiresound
        lda #1
        sta moactive+4,x
        lda modir,x
        sta modir+4,x
        cmp #0
        bne @notup
        lda mox,x
        clc
        adc #8
        sta mox+4,x
        lda moy,x
        sec
        sbc #1
        sta moy+4,x
        rts
@notup  cmp #1
        bne @notdown
        lda mox,x
        clc
        adc #8
        sta mox+4,x
        lda moy,x
        clc
        adc #16
        sta moy+4,x
        rts
@notdown
        cmp #2
        bne @notleft
        lda mox,x
        sec
        sbc #1
        sta mox+4,x
        lda moy,x
        clc
        adc #8
        sta moy+4,x
        rts
@notleft
        lda mox,x
        clc
        adc #16
        sta mox+4,x
        lda moy,x
        clc
        adc #8                ; was 6: firing right, the shell left two
        sta moy+4,x           ; pixels above the barrel. 8, as for the
        rts                   ; players and the other three directions

; ------------------------------------------------------------
; updateenemybullets   move/resolve each active enemy bullet,
;                      checking hits against both players.
;   uses: a, x, y, and everything updatebullet/pointinbox use
; ------------------------------------------------------------
updateenemybullets
        ldx #0
@lp     lda moactive+4,x
        bne @live            ; @next is now out of branch range from
        jmp @next             ; here (the x save/restore below made the
@live                          ; loop body longer) - invert and jmp
        sta bactive
        lda mox+4,x
        sta bx
        lda moy+4,x
        sta by
        lda modir+4,x
        sta bdir
        lda #0                ; enemy shells are always level 0
        sta bstar
        stx etmpx
        jsr updatebullet
        ldx etmpx
        lda bactive
        sta moactive+4,x
        lda bx
        sta mox+4,x
        lda by
        sta moy+4,x
        lda bactive
        beq @next             ; a wall/base already consumed it
        lda p1alive
        beq @notp1b
        lda p1x
        sta pibx
        lda p1y
        sta piby
        jsr pointinbox
        bcc @notp1b
        lda #0
        sta moactive+4,x
        stx etmpx            ; hittank1 -> drawsidebar uses x as a
        jsr hittank1          ; digit counter (ldx #48 for the wave
        ldx etmpx             ; readout) and leaves it at ~48-57.
                               ; without saving/restoring it here, the
                               ; @next inx/cpx #4 below resumes from
                               ; that garbage value, never equals 4,
                               ; and the loop runs ~256 more times
                               ; writing moactive/mox/moy far past
                               ; their 8-byte arrays - straight over
                               ; the dirdx/biasthresh/fieldrow*/
                               ; screenrow* tables that follow. that
                               ; is the memory corruption seen in the
                               ; crash snapshot: once fieldrowlo/hi
                               ; are zeroed, tileat reads tile values
                               ; from zero page instead of the field,
                               ; so every collision probe returns
                               ; garbage - which is exactly "no tank,
                               ; player or ai, can move, and bullets
                               ; vanish instantly in most directions".
        jmp @next
@notp1b lda p2alive
        beq @next
        lda p2x
        sta pibx
        lda p2y
        sta piby
        jsr pointinbox
        bcc @next
        lda #0
        sta moactive+4,x
        stx etmpx            ; same for hittank2 - and this one falls
        jsr hittank2          ; straight through into @next, so the
        ldx etmpx             ; clobbered x would be used immediately
@next   inx
        cpx #4
        beq @alldone         ; loop-back is out of range now too -
        jmp @lp               ; invert and jmp, same as @lp's entry
@alldone
        rts

; ------------------------------------------------------------
; killenemy   a bullet just hit enemy x: lose a hit point, and
;             remove it from the field (awarding points) once
;             they run out. checks whether that was the last
;             enemy standing, starting the next wave if so.
;   in:   x = enemy index (0-3)
;   uses: a, x, y
; ------------------------------------------------------------
killenemy
        dec ehp,x
        lda ehp,x
        bne @done
        lda #0
        sta moactive,x
        stx ktmp
        lda mobonus,x         ; the manual says DESTROY the flashing
        beq @nodrop           ; tank, not merely hit it - which matters
        lda #0                ; now a heavy takes four shells
        sta mobonus,x
        jsr trypowerup
        ldx ktmp
@nodrop
        jsr boomat
        ldx ktmp
        jsr playexplosion
        ldx ktmp
        jsr addscore
        ldy killer            ; tally kills for the stage bonus
        lda p1kills,y
        clc
        adc #1
        sta p1kills,y
        jsr checkwaveclear
@done   rts

; ------------------------------------------------------------
; addhundreds   add a bcd amount to one player's score.
;   in:   a = bcd hundreds to add, y = player (0 or 1)
;   uses: a, x
; ------------------------------------------------------------
addhundreds
        sta addtmp
        ldx #0
        cpy #0
        beq @have
        ldx #3
@have   sed
        clc
        lda score+1,x
        adc addtmp
        sta score+1,x
        lda score+2,x
        adc #0
        sta score+2,x
        cld
        rts

; ------------------------------------------------------------
; addscore   award points for enemy x's type (100/200/300 for
;            basic/fast/armored) into the 3-byte bcd score.
;   in:   x = enemy index (0-3)
;   uses: a
; ------------------------------------------------------------
addscore
        ldy etype,x           ; 100/200/300/400 by type, per the manual
        lda typescore,y
        ldy killer            ; to whoever fired the shell
        jsr addhundreds
        jsr marksidebar
        rts

; ------------------------------------------------------------
; rampdifficulty   tighten the enemies' move and fire cadence by
;                  one wave. they start slack (40/80) and take a
;                  dozen waves to reach the floors (16/45); this
;                  used to live inline in newwave, and a game
;                  started from a later stage began at wave-1
;                  slackness - setupgame now applies it too.
;   uses: a
; ------------------------------------------------------------
rampdifficulty
        lda basemovetimer
        sec
        sbc #3
        cmp #16
        bcs @moveok
        lda #16
@moveok sta basemovetimer
        lda basefiretimer
        sec
        sbc #9
        cmp #45
        bcs @fireok
        lda #45
@fireok sta basefiretimer
        rts

; ------------------------------------------------------------
; checkwaveclear   every enemy slot empty? start the next wave.
;   uses: a
; ------------------------------------------------------------
checkwaveclear
        lda endgame           ; the field is empty, but it is not a clear
        ora duelmode          ; (and a duel has no waves to clear: this
        beq @check            ; would otherwise rebuild the arena mid-fight)
        rts
@check  lda stageleft
        bne @notclear         ; more still to come - not clear yet
        lda moactive+0
        ora moactive+1
        ora moactive+2
        ora moactive+3
        bne @notclear
        jsr dronecheck        ; every third wave, the bonus drone first
        bcs @notclear
        jsr newwave
@notclear
        rts

; ------------------------------------------------------------
; stagebonus   1000 points to whichever player destroyed more enemies
;              this stage, as the manual describes. only in a
;              two-player game - there is nobody to beat otherwise.
;   uses: a, x, y
; ------------------------------------------------------------
stagebonus
        lda nplayers
        cmp #2
        bne @none
        lda p1kills
        cmp p1kills+1
        beq @none             ; a draw pays nobody
        bcs @p1wins
        lda #1
        jmp @pay
@p1wins lda #0
@pay    tay                   ; the winning player
        lda #$10              ; 1000, in bcd hundreds
        jsr addhundreds
        jsr marksidebar
@none   lda #0
        sta p1kills
        sta p1kills+1
        rts

; ------------------------------------------------------------
; startwavebanner   hold the field and announce the stage. the
;                   previous build cut straight from the last kill
;                   of one wave into the first arrival of the next,
;                   with no beat in between to read what happened.
;   uses: a, x, y
; ------------------------------------------------------------
startwavebanner
        lda #wavepause
        sta wavewait
        jsr clearobjects      ; nothing from the stage just finished may
                               ; still be on screen behind the banner
        lda anon              ; the 1812 ditty, as the stage is announced
        bne @playing          ; - unless it is already playing, the
        jsr dittystart        ; fanfare for shooting the drone down: that
@playing                       ; doubles as this banner's music, rather
        rts                   ; than being cut short and started again

; ------------------------------------------------------------
; clearobjects   take every tank and shell off the field, and empty
;                the multiplexer's display list with them.
;
;                clearing the arrays alone is not enough: the main
;                loop stops calling buildsprites while the banner is
;                up, so the display list keeps whatever it held when
;                the stage ended, and the raster chain goes on
;                drawing it. the last stage's tanks sat frozen on
;                the new one's map.
;   uses: a, x
; ------------------------------------------------------------
clearobjects
        ldx #0
        lda #0
@lp     sta moactive,x        ; four tanks and four enemy shells
        inx
        cpx #8
        bne @lp
        ldx #0
@lp2    lda #0
        sta pbactive,x        ; and the players' shells
        inx
        cpx #4
        bne @lp2
        lda #0
        sta dspcnt            ; both banks of the display list
        sta dspcnt+1
        sta muxidx
        sta muxslot
        lda #0                ; and EVERY sprite off, players included.
        sta d015               ; their positions are written by
        rts                    ; updateplayers, which does not run while
                                ; the banner is up - so the two player
                                ; tanks stayed frozen at wherever they
                                ; stood when the last stage ended.

; ------------------------------------------------------------
; updatewave   count the banner down, then clear it and let play
;              begin. the banner is drawn once, on the first tick,
;              so it survives readlevel having redrawn the field.
;   uses: a, x, y
; ------------------------------------------------------------
updatewave
        jsr anthemrun         ; the ditty
        lda wavewait
        cmp #wavepause
        bne @count
        jsr drawwavebanner
@count  dec wavewait
        bne @done
        jsr anthemstop        ; the banner is gone: voice 3 is the game's again
        jsr clearwavebanner
        lda p1alive           ; the players reappear with the field -
        beq @nop1             ; but only the ones still in the game
        lda d015
        ora #%00000001
        sta d015
@nop1   lda nplayers
        cmp #2
        bne @solo
        lda p2alive
        beq @solo
        lda d015
        ora #%00000010
        sta d015
@solo
@done   rts

; ------------------------------------------------------------
; drawwavebanner / clearwavebanner   "WAVE nn" across the middle of
;   the field, then the field put back from the buffer underneath.
;   uses: a, x, y, trow, tcol, pchar, pcol
; ------------------------------------------------------------
drawwavebanner
        lda #12               ; row 12, col 9 - the middle of the field
        sta trow
        lda duelmode          ; a duel has no waves, just the one arena:
        beq @wave             ; the number would mean nothing
        lda #8                ; "GET READY", nine characters from column 8:
        sta tcol              ; the same centre as "WAVE nn"
        ldy #0
@gr     lda readytext,y
        sta pchar
        lda #1                ; white
        sta pcol
        sty bantmp
        jsr putchar
        ldy bantmp
        inc tcol
        iny
        cpy #9
        bne @gr
        rts
@wave   lda #9
        sta tcol
        ldy #0
@lp     lda wavetext,y
        sta pchar
        lda #1                ; white
        sta pcol
        sty bantmp
        jsr putchar
        ldy bantmp
        inc tcol
        iny
        cpy #5
        bne @lp
        lda wave              ; the number, two digits
        ldx #48
@tens   cmp #10
        bcc @units
        sec
        sbc #10
        inx
        jmp @tens
@units  clc
        adc #48
        sta bandig
        stx pchar
        lda #1
        sta pcol
        jsr putchar
        inc tcol
        lda bandig
        sta pchar
        lda #1
        sta pcol
        jsr putchar
        rts

clearwavebanner
        lda #12
        sta trow
        lda #8                ; wide enough for "GET READY" (cols 8-16);
        sta tcol              ; "WAVE nn" is cols 9-15 inside it
        ldy #0
@lp     sty bantmp
        jsr drawfieldcell     ; put back whatever the field holds there
        ldy bantmp
        inc tcol
        iny
        cpy #9
        bne @lp
        rts

; ------------------------------------------------------------
; drawbonusbanner / clearbonusbanner   "BONUS ROUND" across the
;   middle of the field during the pause before the drone.
;   eleven characters from column 7 - wider than the wave
;   banner's window, so it clears its own.
;   uses: a, x, y, trow, tcol, pchar, pcol, bantmp
; ------------------------------------------------------------
drawbonusbanner
        lda #12
        sta trow
        lda #7
        sta tcol
        ldy #0
@lp     lda bonustext,y
        sta pchar
        lda #dronecol         ; the drone's own light green
        sta pcol
        sty bantmp
        jsr putchar
        ldy bantmp
        inc tcol
        iny
        cpy #11
        bne @lp
        rts

clearbonusbanner
        lda #12
        sta trow
        lda #7
        sta tcol
        ldy #0
@lp     sty bantmp
        jsr drawfieldcell
        ldy bantmp
        inc tcol
        iny
        cpy #11
        bne @lp
        rts

bonustext byte 2,15,14,21,19,32,18,15,21,14,4   ; "BONUS ROUND"
wavetext byte 23,1,22,5,32    ; "WAVE "
readytext byte 7,5,20,32,18,5,1,4,25   ; "GET READY"

; ------------------------------------------------------------
; newwave   advance the wave counter, respawn a fresh batch of
;           enemies, and nudge the difficulty up a little -
;           shorter move/fire timers, each floored so it never
;           becomes instant/unfair.
;   uses: a
; ------------------------------------------------------------
newwave
        jsr stagebonus
        inc wave
        lda wave              ; the wave number is two digits wide, and
        cmp #100              ; ninety-nine stages cleared. there is
        bcc @carryon          ; nothing further to throw at anyone who
        jsr startending       ; has got this far - except one thing
        rts
@carryon
        jsr rampdifficulty     ; one wave tighter
        jsr buildspawnlist    ; the formation for the stage we are now
        jsr startwavebanner   ; on. this used to live only in setupgame,
                               ; so the list was built once for the
                               ; starting stage and never again - every
                               ; later wave reused stage 1's twenty light
                               ; tanks, whatever its own formation said
        jsr readlevel         ; fresh field for the new wave. without
                               ; this the wave carried over the previous
                               ; one's rubble - including the brick nest
                               ; round the base, which by wave 2 was
                               ; usually gone entirely, leaving the
                               ; eagle in the open. the original loads a
                               ; whole new stage at this point, so
                               ; restoring every destroyed brick (not
                               ; just the nest) is the matching
                               ; behaviour. readlevel also puts both
                               ; players back on their spawn markers,
                               ; which is what the original does between
                               ; stages too.
        jsr resetextras       ; the reload wiped any burst or
        jsr spawnenemies      ; pickup that was on the field
        jsr drawsidebar
        rts

; ==============================================================
; STAGE 7: sound effects (voice 3 - shots and explosions)
; ==============================================================

; ------------------------------------------------------------
; initsound   clear all 25 sid registers (the chip keeps state
;             across runs, so a cold start can inherit garbage)
;             and set master volume. voice 3 is dedicated to
;             sound effects; a one-shot sound is triggered by
;             forcing the gate through a 0->1 transition (the
;             sid only starts a fresh attack on that edge) with
;             sustain=0, so it fades to silence on its own via
;             decay - no timer needed to turn it back off.
;   uses: a, x
; ------------------------------------------------------------
initsound
        ldx #24
        lda #0
@lp     sta $d400,x
        dex
        bpl @lp
        lda #15
        sta $d418          ; full master volume, filters off
        rts

; ------------------------------------------------------------
; playfiresound   short pulse blip on voice 3, for any shot -
;                 player or enemy.
;   uses: a
; ------------------------------------------------------------
playfiresound
        lda $d412
        and #%11111110     ; gate off first - forces the next gate-on
        sta $d412          ; to be a real 0->1 edge, retriggering
        lda #<9000         ; noise, not a tone. a pulse waveform at a
        sta $d40e          ; fixed pitch is a beep however short you
        lda #>9000         ; make it, which is why firing sounded like
        sta $d40f          ; a bat hitting a ball. high noise pitch
        lda #2             ; gives a bright crack; attack 0, decay ~48ms
        sta $d413          ; so it is gone before the next shot
        lda #0             ; sustain 0 - decays to silence on its own
        sta $d414
        lda #129           ; NOISE waveform + gate on
        sta $d412
        rts

; ------------------------------------------------------------
; playexplosion   short noise burst on voice 3, for a kill, a
;                 tank getting hit, or the base going down.
;   uses: a
; ------------------------------------------------------------
playexplosion
        lda $d412
        and #%11111110
        sta $d412
        lda #<1400         ; much lower than the shot: the two are both
        sta $d40e          ; noise now, so pitch and length are what
        lda #>1400         ; tell them apart. low and long reads as a
        sta $d40f          ; detonation, high and short as a crack.
        lda #9             ; attack 0, decay ~750ms - it rumbles away
        sta $d413
        lda #0
        sta $d414
        lda #129           ; noise waveform + gate on
        sta $d412
        rts

; ------------------------------------------------------------
; rand256   white flame's full-period lfsr (maths.md) - cheap,
;           good for per-frame ai jitter, not for anything a
;           player could learn the pattern of.
;   out:  a = seed = next pseudo-random byte
;   uses: a
; ------------------------------------------------------------
rand256 lda seed
        beq @eor
        clc
        asl
        beq @no
        bcc @no
@eor    eor #$1d
@no     sta seed
        rts

; ------------------------------------------------------------
; candir   is direction a clear of terrain for the tank in slot x?
;          other tanks are ignored: they move, so a direction
;          blocked by one now may be open by the time the tank
;          gets there, and the mover checks them anyway.
;   in:   a = direction, x = enemy slot
;   out:  carry set if clear
;   uses: a, cx, cy, trow, tcol
; ------------------------------------------------------------
candir  sta cdtmp
        lda othercount
        sta cdsave
        lda #0
        sta othercount
        lda mox,x
        sta cx
        lda moy,x
        sta cy
        stx cdx
        lda cdtmp
        cmp #0
        bne @d1
        jsr checkup
        jmp @done
@d1     cmp #1
        bne @d2
        jsr checkdown
        jmp @done
@d2     cmp #2
        bne @d3
        jsr checkleft
        jmp @done
@d3     jsr checkright
@done   ldx cdx
        lda cdsave
        sta othercount
        lda cdtmp
        rts

; ------------------------------------------------------------
; computebasepref   which single direction (0-3) would move
;                   enemy x one step closer to the base's
;                   pixel centre? horizontal correction takes
;                   priority over vertical whenever both axes
;                   are off - an arbitrary but consistent
;                   choice (see updateenemies' header comment).
;                   falls back to "down" in the practically-
;                   unreachable case of being exactly centred
;                   on both axes already.
;   in:   x = enemy index (0-3)
;   out:  prefdir
;   uses: a
; ------------------------------------------------------------
; two directions now, not one. the old routine walked the horizontal
; axis until it lined up and only then went vertical - so a tank with
; its sideways route blocked fell straight through to a random pick,
; even though down was also toward the base. prefalt is that second
; direction; 255 means the tank is already lined up on that axis.
computebasepref
        lda #255
        sta prefalt
        lda mox,x             ; horizontal component: the tank's CENTRE
        clc                   ; against the reactor's. mox is its left
        adc #8                ; edge, so it used to aim a cell to the
        cmp #basetargetx      ; right - in a corridor one block wide, a
                               ; spot it could never reach
        beq @novert
        bcc @needright
        lda #2
        sta prefdir
        jmp @vertalt
@needright
        lda #3
        sta prefdir
@vertalt
        lda moy,x             ; and the vertical one, as the fallback
        cmp #basetargety
        beq @done2
        bcc @altdown
        lda #0
        sta prefalt
        rts
@altdown
        lda #1
        sta prefalt
@done2  rts
@novert
        lda moy,x
        cmp #basetargety
        beq @aligned
        bcc @needdown
        lda #0                ; enemy is below the base -> go up
        sta prefdir
        rts
@needdown
        lda #1                ; enemy is above the base -> go down
        sta prefdir
        rts
@aligned
        lda #1                ; exactly centred - arbitrary fallback
        sta prefdir
        rts

; ------------------------------------------------------------
; readlevel   builds everything from level1 in a SINGLE pass
;             (spawn detection, field copy+normalise, and the
;             screen draw all happen per-cell in one loop) -
;             record every spawn marker's pixel position, write
;             the (4/5/6-normalised) tile value into the
;             writable `field` buffer, and draw that cell to the
;             screen, all before moving to the next cell.
;             this used to be 4 separate 650-cell passes
;             (scanspawns, copylevel, normfield, then the draw
;             loop) - roughly 96,000 cycles, close to 5 whole
;             game ticks, which is exactly the kind of thing
;             that shows up as "the game freezes for a moment"
;             right when a round starts or restarts. one pass
;             cuts that to roughly a quarter.
;   uses: a, x, y, lvlptr, dstptr, scrptr, colptr, rowbuf, colbuf
; ------------------------------------------------------------
readlevel
        lda duelmode
        beq @stage
        jmp readduel
@stage  jsr clearscreen       ; the old loader cleared as it drew; this
                               ; one only paints the field, so without
                               ; this the sidebar background keeps
                               ; whatever was in screen memory
        lda wave              ; wave 1 is stage 1; past 35 it wraps...
        cmp #99               ; ...except the last: wave 99 has a map of
        bne @normal           ; its own, the 36th, straight after the 35
        lda #35
        bne @haveidx
@normal lda wave
        sec
        sbc #1
@wrap   cmp #35
        bcc @haveidx
        sec
        sbc #35
        jmp @wrap
@haveidx
        tax                   ; lvlptr = leveldata + index*72. adding in
        lda #<leveldata       ; a loop beats a 16-bit multiply for a
        sta dstptr            ; value that runs to 34 and only at load.
        lda #>leveldata       ; NOT lvlptr: setfieldcell and tileat both
        sta dstptr+1          ; use that as scratch, so the level
@addlp  cpx #0                ; pointer would be destroyed by the first
        beq @cleared          ; cell written
        clc
        lda dstptr
        adc #72
        sta dstptr
        lda dstptr+1
        adc #0
        sta dstptr+1
        dex
        jmp @addlp

@cleared
        ldx #0                ; everything floor to begin with
@clrlp  lda #0
        sta field,x
        sta field+256,x
        sta field+512,x
        inx
        bne @clrlp
        ldx #0                ; field is 650, so 138 more past 512
@clr2   cpx #138
        beq @expand
        lda #0
        sta field+512,x
        inx
        jmp @clr2

@expand lda #0                ; walk the 143 blocks
        sta blkn
        lda #blktop
        sta trow
@rowlp  lda #0
        sta tcol
@collp  jsr blockat           ; a = tile value for block blkn
        sta blkval
        jsr stampblock        ; 2x2 cells at (trow,tcol)
        inc blkn
        lda tcol
        clc
        adc #2
        sta tcol
        cmp #26
        bne @collp
        lda trow
        clc
        adc #2
        sta trow
        cmp #blktop+22
        bne @rowlp

        lda #baserow          ; the fixed furniture, identical every
        sta trow               ; stage, so it is not in the level data
        lda #basecol
        sta tcol
        lda #3
        jsr setfieldcell
        inc tcol
        lda #3
        jsr setfieldcell
        inc trow
        lda #basecol
        sta tcol
        lda #3
        jsr setfieldcell
        inc tcol
        lda #3
        jsr setfieldcell
        lda #brickfull
        jsr setnestcells

        lda #24+8*8           ; the player spawns flank the base
        sta p1x
        lda #50+23*8
        sta p1y
        lda #24+16*8
        sta p2x
        lda #50+23*8
        sta p2y
        lda #0
        sta p1xmsb
        sta p2xmsb
        lda #3                ; three entry points along the top
        jsr drawfield
        jsr drawdivider
        rts

; ------------------------------------------------------------
; readduel   lay out the versus map. its grid is 12 block rows with
;            the spare row in the middle, so both halves mirror;
;            both bases and both nests are stamped by code, exactly
;            as the single base is in a normal stage.
;   uses: a, x, y
; ------------------------------------------------------------
readduel
        jsr clearscreen
        lda #<duelmap
        sta dstptr
        lda #>duelmap
        sta dstptr+1
        ldx #0                ; floor everywhere first
@clrlp  lda #0
        sta field,x
        sta field+256,x
        inx
        bne @clrlp
        ldx #0
@clr2   cpx #138
        beq @expand
        lda #0
        sta field+512,x
        inx
        jmp @clr2
@expand lda #0
        sta blkn
        sta dbrow
@rowlp  lda dbrow             ; cells = br*2, and one more past the
        asl a                 ; middle where the spare row sits
        sta trow
        lda dbrow
        cmp #6
        bcc @norow
        inc trow
@norow  lda #0
        sta tcol
@collp  jsr blockat
        sta blkval
        jsr stampblock
        inc blkn
        lda tcol
        clc
        adc #2
        sta tcol
        cmp #26
        bne @collp
        inc dbrow
        lda dbrow
        cmp #12
        bne @rowlp

        lda #baserow          ; player 1's base, bottom
        sta trow
        jsr stampbase
        lda #duelbaserow      ; player 2's, top - the mirror
        sta trow
        jsr stampbase

        lda #24+8*8           ; spawns beside each base
        sta p1x
        lda #50+23*8
        sta p1y
        lda #24+16*8
        sta p2x
        lda #50+0*8
        sta p2y
        lda #0
        sta p1xmsb
        sta p2xmsb
        lda #1                ; both bases standing
        lda #0                ; and no enemies at all in a duel
        jsr drawfield
        jsr drawdivider
        rts

; ------------------------------------------------------------
; stampbase   a base and its nest at row trow. the nest goes on the
;             side facing the middle of the map, so each player's
;             brick is between their eagle and the fight.
;   in:   trow = the base's top row (0 or baserow)
;   uses: a, x, y
; ------------------------------------------------------------
stampbase
        lda trow              ; the four base cells
        sta basetop
        sta trow
        lda #basecol
        sta tcol
        lda #3
        jsr setfieldcell
        inc tcol
        lda #3
        jsr setfieldcell
        inc trow
        lda #basecol
        sta tcol
        lda #3
        jsr setfieldcell
        inc tcol
        lda #3
        jsr setfieldcell
        lda basetop           ; and two layers of brick round them. the
        cmp #3                ; band starts two rows above the bottom
        bcs @below            ; base, or at the top base's own row so it
        lda basetop           ; extends downward into the map
        jmp @haveband
@below  lda basetop
        sec
        sbc #2
@haveband
        sta nesttop
        lda #brickfull
        jmp buildnest

; ------------------------------------------------------------
; blockat   the tile value of block blkn, from the packed nibbles.
;   out:  a = field tile value
;   uses: a, x, y
; ------------------------------------------------------------
blockat lda blkn
        lsr a                 ; two blocks to a byte
        tay
        lda (dstptr),y
        bcs @low              ; carry from the lsr says which nibble
        lsr a
        lsr a
        lsr a
        lsr a
        jmp @have
@low    and #15
@have   tax
        lda blocktile,x
        rts

; ------------------------------------------------------------
; stampblock   write blkval into the 2x2 cells at (trow,tcol).
;   uses: a, x, y
; ------------------------------------------------------------
stampblock
        lda blkval
        beq @done             ; floor is already there
        sta stamptop          ; the whole block, normally...
        sta stampbot
        cmp #halftop          ; ...but the half blocks put steel in one
        bne @nottop           ; pair of cells only: a block is two cells
        lda #armrfull         ; tall, too coarse for the middle bar of
        sta stamptop          ; an E
        lda #0
        sta stampbot
        beq @go
@nottop cmp #halfbottom
        bne @go
        lda #0
        sta stamptop
        lda #armrfull
        sta stampbot
@go     lda stamptop
        jsr setfieldcell
        inc tcol
        lda stamptop
        jsr setfieldcell
        inc trow
        lda stampbot
        jsr setfieldcell
        dec tcol
        lda stampbot
        jsr setfieldcell
        dec trow
        rts
@done   rts

; ------------------------------------------------------------
; setnestcells   the brick nest round the base, value in a.
;   uses: a, x, y
; ------------------------------------------------------------
setnestcells
        sta nestval2          ; two layers, via the shared builder
        lda #baserow-2
        sta nesttop
        lda #baserow
        sta basetop
        lda nestval2
        jmp buildnest

; ------------------------------------------------------------
; buildnest   fill the nest round a base with the value in a.
;
;             two layers thick, not one: a single ring took only a
;             few seconds to chew through, and with the base on the
;             bottom row there is no brick below it at all - every
;             shot that gets past the roof is already on target.
;
;             the nest is the 6x4 band from nesttop, columns
;             basecol-2 to basecol+3, minus the four cells the base
;             itself occupies at basetop.
;   in:   a = tile value, nesttop = first row, basetop = base's row
;   uses: a, x, y, trow, tcol, nestval
; ------------------------------------------------------------
buildnest
        sta nestval
        lda nesttop
        sta trow
        lda #0
        sta nestr
@rowlp  lda #basecol-2
        sta tcol
        lda #0
        sta nestc
@collp  lda trow              ; is this one of the base's own cells?
        cmp basetop
        bcc @fill
        sec
        sbc basetop
        cmp #2
        bcs @fill
        lda tcol
        cmp #basecol
        bcc @fill
        cmp #basecol+2
        bcs @fill
        jmp @next             ; the base sits here - leave it
@fill   lda nestval
        jsr setfieldcell
@next   inc tcol
        inc nestc
        lda nestc
        cmp #6
        bne @collp
        inc trow
        inc nestr
        lda nestr
        cmp #4
        bne @rowlp
        rts

; ------------------------------------------------------------
; drawdivider   a steel column between the field and the sidebar,
;               drawn in screen column 26 - hard against the last
;               column of the playfield, which is where the map's
;               edge should read. the gap is on the other side of
;               it, between the barrier and the readouts.
;               the field used to spend its own column 25 on this;
;               now it is drawn in screen column 26, which belongs
;               to the sidebar, so the playfield keeps all 26
;               columns and the block grid stays 13 wide.
;   uses: a, x, y, scrptr, colptr
; ------------------------------------------------------------
drawdivider
        lda #<($4400+26)
        sta scrptr
        lda #>($4400+26)
        sta scrptr+1
        lda #<($d800+26)
        sta colptr
        lda #>($d800+26)
        sta colptr+1
        ldx #25
@lp     ldy #0
        lda #steelchr
        sta (scrptr),y
        lda #15               ; light grey, as armour is
        sta (colptr),y
        clc
        lda scrptr
        adc #40
        sta scrptr
        lda scrptr+1
        adc #0
        sta scrptr+1
        clc
        lda colptr
        adc #40
        sta colptr
        lda colptr+1
        adc #0
        sta colptr+1
        dex
        bne @lp
        rts

; ------------------------------------------------------------
; drawfield   paint every cell of the field from the buffer.
;   uses: a, x, y
; ------------------------------------------------------------
drawfield
        lda #0
        sta trow
@rowlp  lda #0
        sta tcol
@collp  jsr drawfieldcell
        inc tcol
        lda tcol
        cmp #26
        bne @collp
        inc trow
        lda trow
        cmp #25
        bne @rowlp
        rts

; tile value for each nibble code
blocktile byte 0,brickfull,armrfull,tileriver,tileforest,tileice
        byte halftop,halfbottom       ; 6, 7: steel in one pair of cells only
        byte 0,0,0,0,0,0,0,0

; ------------------------------------------------------------
; clearsidebar   blank screen columns 26-39, all 25 rows - the
;                status panel area. placeholder (black, space)
;                until the polish stage draws real status text.
;   uses: a, x, y, scrptr, colptr
; ------------------------------------------------------------
; drawsidebar   redraw the score/wave/lives readout in the
;               sidebar. called whenever one of those actually
;               changes (a kill, a wave clear, a life lost) -
;               not every tick, since none of them change that
;               often and a full sidebar redraw every tick would
;               be wasteful.
;   uses: a, x, y, scrptr, colptr
; ------------------------------------------------------------
drawsidebar
        lda #<($4400+1*40+28)
        sta scrptr
        lda #>($4400+1*40+28)
        sta scrptr+1
        lda #<($d800+1*40+28)
        sta colptr
        lda #>($d800+1*40+28)
        sta colptr+1
        ldy #0
@lbl1   lda scorelbl,y
        sta (scrptr),y
        lda #1
        sta (colptr),y
        iny
        cpy #5
        bne @lbl1

        lda #<($4400+2*40+28)
        sta scrptr
        lda #>($4400+2*40+28)
        sta scrptr+1
        lda #<($d800+2*40+28)
        sta colptr
        lda #>($d800+2*40+28)
        sta colptr+1
        lda #0                ; player 1's score, always shown
        sta scoreof
        lda #6                ; dark blue, matching the tank
        sta scorecol
        jsr drawonescore
        lda nplayers          ; player 2's underneath, only in a
        cmp #2                ; two-player game
        bne @noscore2
        lda #<($4400+3*40+28)
        sta scrptr
        lda #>($4400+3*40+28)
        sta scrptr+1
        lda #<($d800+3*40+28)
        sta colptr
        lda #>($d800+3*40+28)
        sta colptr+1
        lda #3
        sta scoreof
        lda #7                ; yellow, matching the tank
        sta scorecol
        jsr drawonescore
@noscore2

        lda #<($4400+5*40+28)
        sta scrptr
        lda #>($4400+5*40+28)
        sta scrptr+1
        lda #<($d800+5*40+28)
        sta colptr
        lda #>($d800+5*40+28)
        sta colptr+1
        ldy #0
@lbl2   lda wavelbl,y
        sta (scrptr),y
        lda #1
        sta (colptr),y
        iny
        cpy #4
        bne @lbl2

        lda #<($4400+6*40+28)
        sta scrptr
        lda #>($4400+6*40+28)
        sta scrptr+1
        lda #<($d800+6*40+28)
        sta colptr
        lda #>($d800+6*40+28)
        sta colptr+1
        lda wave
        ldx #48
@divloop
        cmp #10
        bcc @dosingle
        sec
        sbc #10
        inx
        jmp @divloop
@dosingle
        pha
        txa
        ldy #0
        sta (scrptr),y
        lda #1
        sta (colptr),y
        pla
        clc
        adc #48
        ldy #1
        sta (scrptr),y
        lda #1
        sta (colptr),y

        lda #<($4400+14*40+28)   ; enemies left in this stage - with
        sta scrptr                ; only 4 on the field at a time the
        lda #>($4400+14*40+28)    ; player otherwise has no idea how
        sta scrptr+1              ; much of the stage is still coming
        lda #<($d800+14*40+28)
        sta colptr
        lda #>($d800+14*40+28)
        sta colptr+1
        ldy #0
@lbl5   lda leftlbl,y
        sta (scrptr),y
        lda #1
        sta (colptr),y
        iny
        cpy #5
        bne @lbl5
        lda stageleft
        ldx #48
@dvlp   cmp #10
        bcc @dvdone
        sec
        sbc #10
        inx
        jmp @dvlp
@dvdone pha
        txa
        ldy #5
        sta (scrptr),y
        lda #1
        sta (colptr),y
        pla
        clc
        adc #48
        ldy #6
        sta (scrptr),y
        lda #1
        sta (colptr),y

        lda #<($4400+8*40+28)
        sta scrptr
        lda #>($4400+8*40+28)
        sta scrptr+1
        lda #<($d800+8*40+28)
        sta colptr
        lda #>($d800+8*40+28)
        sta colptr+1
        ldy #0
@lbl3   lda p1lbl,y
        sta (scrptr),y
        lda #1
        sta (colptr),y
        iny
        cpy #3
        bne @lbl3
        lda p1lives
        clc
        adc #48
        ldy #3
        sta (scrptr),y
        lda #1
        sta (colptr),y

        lda #<($4400+11*40+28)
        sta scrptr
        lda #>($4400+11*40+28)
        sta scrptr+1
        lda #<($d800+11*40+28)
        sta colptr
        lda #>($d800+11*40+28)
        sta colptr+1
        ldy #0
@lbl4   lda p2lbl,y
        sta (scrptr),y
        lda #1
        sta (colptr),y
        iny
        cpy #3
        bne @lbl4
        lda p2lives
        clc
        adc #48
        ldy #3
        sta (scrptr),y
        lda #1
        sta (colptr),y

        lda #0                ; gun level as pips under each player's
        sta pipwho            ; lives - no sprite needed, and it is
        jsr drawpips          ; readable at a glance mid-game
        lda #1
        sta pipwho
        jsr drawpips
        jsr drawreserve
        rts

; ------------------------------------------------------------
; drawreserve   the tanks still to come this stage, drawn as a
;               row of little tank icons under LEFT: rather than
;               only as a number - the way the original shows it.
;               20 icons, four to a row over five rows; cells
;               past the count are blanked, so the block shrinks
;               as the stage is worked through.
;   uses: a, x, y, scrptr, colptr, rsvi
; ------------------------------------------------------------
drawreserve
        lda #<($4400+16*40+29)
        sta scrptr
        lda #>($4400+16*40+29)
        sta scrptr+1
        lda #<($d800+16*40+29)
        sta colptr
        lda #>($d800+16*40+29)
        sta colptr+1
        lda #0
        sta rsvi
        ldx #0                ; x = row of icons, 5 of them
@rowlp  ldy #0
@collp  lda rsvi
        cmp stageleft
        bcs @blank
        lda #minitank
        jmp @put
@blank  lda #32
@put    sta (scrptr),y
        lda #1                ; white, like the other readouts
        sta (colptr),y
        inc rsvi
        iny
        cpy #4
        bne @collp
        clc                   ; next icon row
        lda scrptr
        adc #40
        sta scrptr
        lda scrptr+1
        adc #0
        sta scrptr+1
        clc
        lda colptr
        adc #40
        sta colptr
        lda colptr+1
        adc #0
        sta colptr+1
        inx
        cpx #5
        bne @rowlp
        rts

; ------------------------------------------------------------
; drawonescore   six bcd digits at scrptr/colptr, from the score
;                starting at score+scoreof, in colour scorecol.
;   uses: a, x, y
; ------------------------------------------------------------
drawonescore
        ldy #0
        ldx #2
@lp     txa
        clc
        adc scoreof
        tax
        lda score,x
        lsr
        lsr
        lsr
        lsr
        clc
        adc #48
        sta (scrptr),y
        lda scorecol
        sta (colptr),y
        iny
        lda score,x
        and #15
        clc
        adc #48
        sta (scrptr),y
        lda scorecol
        sta (colptr),y
        iny
        txa
        sec
        sbc scoreof
        tax
        dex
        bpl @lp
        rts

; ------------------------------------------------------------
; drawpips   three cells under player pipwho's lives count, filled
;            with a star for each level of gun upgrade. the star is
;            the same glyph the power-up uses, so it reads as "you
;            picked up that many stars".
;   uses: a, x, y, scrptr, colptr
; ------------------------------------------------------------
drawpips
        lda pipwho
        bne @p2
        lda #<($4400+9*40+28)
        sta scrptr
        lda #>($4400+9*40+28)
        sta scrptr+1
        lda #<($d800+9*40+28)
        sta colptr
        lda #>($d800+9*40+28)
        sta colptr+1
        lda p1star
        jmp @have
@p2     lda #<($4400+12*40+28)
        sta scrptr
        lda #>($4400+12*40+28)
        sta scrptr+1
        lda #<($d800+12*40+28)
        sta colptr
        lda #>($d800+12*40+28)
        sta colptr+1
        lda p2star
@have   sta pipn
        ldy #0
@lp     cpy pipn
        bcs @blank
        lda #pipstar
        jmp @put
@blank  lda #32
@put    sta (scrptr),y
        lda #7                ; yellow
        sta (colptr),y
        iny
        cpy #3
        bne @lp
        rts

scorelbl byte 19,3,15,18,5      ; "SCORE"
wavelbl byte 23,1,22,5          ; "WAVE"
p1lbl   byte 16,49,58           ; "P1:"
p2lbl   byte 16,50,58           ; "P2:"
leftlbl byte 12,5,6,20,58       ; "LEFT:"

; ==============================================================
; STAGE 9: explosions and power-ups
; ==============================================================
;   all of this is drawn with characters rather than sprites. the
;   8 hardware sprites are already fully committed - 0-3 to the
;   players and their bullets, 4-7 to the multiplexed enemy pool -
;   so there is nothing spare for a burst or a pickup. since the
;   playfield is a character grid anyway, a 2x2 block of custom
;   glyphs sits on it exactly like a tile, and clearing it is just
;   redrawing those four cells from the field buffer.
; ------------------------------------------------------------
explchr1 = 102           ; explosion, first frame (2x2)
explchr2 = 106           ; explosion, second frame
pwdrone  = 110           ; drone strike - blue drones take out every
                         ; tank on the field
pwshov   = 114           ; shovel   - steel shield round the base
pwwatch  = 118           ; watch    - freezes the tanks
expltime = 16            ; ticks a burst stays on screen
explhalf = 8             ; ticks at which it switches to frame 2
freezeset = 50           ; prescaled units (8 ticks each) - about 8s
shieldset = 125          ; about 20s
pwtank   = 122           ; extra life
pwhelm   = 126           ; temporary shield
pwstar   = 130           ; gun upgrade
helmetset = 60           ; prescaled units (8 ticks) - about 10s
maxstar  = 3             ; per the manual: 1 faster shells, 2 two-shot
                          ; firing, 3 destroys armour. i had 2 and 3 the
                          ; wrong way round.
spawnticks = 60          ; ticks the entry marker pulses first
spawnretry = 12          ; and how long it waits if the spot is taken          ; ticks the entry marker pulses first
attractdwell = 160       ; ticks each briefing page stays up
attractidle = 94         ; x8 ticks = 15 seconds of title screen
                          ; before the briefing comes up       ; ticks each attract entry stays up
wavepause = 150          ; ticks the wave banner holds - 3 seconds
endhold = 50*60          ; the ending's white screen: one minute
gopause = 175            ; ticks game over holds before it will
                          ; take any input at all - 3.5 seconds
firecool  = 26           ; minimum ticks between shots. without it the
firecoolup = 18          ; only limit is the shell's flight time, so a
                          ; tank with its muzzle against a wall could
                          ; fire three times a second and drill straight
                          ; through. a starred gun reloads quicker, so
                          ; the upgrade still means something up close.
deathpause = 75          ; ticks the wreck burns before you are back
respawnmercy = 19        ; prescaled units (x8 ticks) of shield on
                          ; returning - about 3 seconds, long enough to
                          ; get clear of a spawn point something is
                          ; already shooting at. the tank flashes
                          ; throughout, so it is visible that it is on.
hunterturn = 180         ; ticks one tank spends as the runner
; movement is one pixel a tick, which is the smallest step there is -
; so slowing a tank down means skipping ticks, not moving less. a tank
; sits out one tick in eight: 44 pixels a second against the full 50.
; one in four was tried first and read as sluggish. the armoured car
; is the exception and keeps the full rate, which is what makes it the
; fast one - and the only thing that gap can be is a whole tick, so
; the choices here are 50, 44, 42, 38 and down, nothing between.
turnhold = 32            ; ticks a blocked turn is treated as an
                          ; early corner before it becomes a
                          ; turn-to-face. about half a second, or
                          ; roughly three tiles of run-up at 44 px/sec.
movemask = 7             ; skip the tick where (movephase & 7) == 7
iceslide = 24            ; ticks a tank keeps going on ice (was 12:
                         ; barely a tank's width, it hardly felt like ice)
pwlifeset = 90           ; prescaled units (8 ticks) an item lasts - 14s
pwflash  = 25            ; start blinking with this many units left - 4s

; ------------------------------------------------------------
; putchar   write one character + colour to screen cell
;           (trow,tcol), via the row tables.
;   in:   trow, tcol, pchar, pcol
;   uses: a, x, y, scrptr, colptr
; ------------------------------------------------------------
putchar ldx trow
        lda #<$4400
        clc
        adc screenrowlo,x
        sta scrptr
        lda #>$4400
        adc screenrowhi,x
        sta scrptr+1
        lda #<$d800
        clc
        adc screenrowlo,x
        sta colptr
        lda #>$d800
        adc screenrowhi,x
        sta colptr+1
        ldy tcol
        lda pchar
        sta (scrptr),y
        lda pcol
        sta (colptr),y
        rts

; ------------------------------------------------------------
; draw2x2   stamp a 4-glyph block (tl tr bl br, consecutive
;           codes from gbase) at (g2row,g2col) in colour gcol.
;   uses: a, x, y, trow, tcol, pchar, pcol
; ------------------------------------------------------------
draw2x2 lda gcol
        sta pcol
        lda g2row
        sta trow
        lda g2col
        sta tcol
        lda gbase
        sta pchar
        jsr putchar
        inc tcol
        inc pchar
        jsr putchar
        inc trow
        lda g2col
        sta tcol
        lda gbase
        clc
        adc #2
        sta pchar
        jsr putchar
        inc tcol
        inc pchar
        jsr putchar
        rts

; ------------------------------------------------------------
; setfieldcell   field[trow][tcol] = a
;   uses: a, x, y, lvlptr, sfval
; ------------------------------------------------------------
setfieldcell
        sta sfval
        ldx trow
        lda #<field
        clc
        adc fieldrowlo,x
        sta lvlptr
        lda #>field
        adc fieldrowhi,x
        sta lvlptr+1
        ldy tcol
        lda sfval
        sta (lvlptr),y
        rts

; ------------------------------------------------------------
; drawfieldcell   redraw screen cell (trow,tcol) from whatever
;                 the field buffer currently holds there.
;   uses: a, x, y, rowbuf, colbuf, outcol, scrptr, colptr
; ------------------------------------------------------------
drawfieldcell
        jsr tileat
        pha
        lda trow
        sta rowbuf            ; decodetile needs these to pick the
        lda tcol              ; right quadrant of the eagle
        sta colbuf
        pla
        jsr decodetile
        sta pchar
        lda outcol
        sta pcol
        jsr putchar
        rts

; ------------------------------------------------------------
; restore2x2   redraw the 4 cells at (g2row,g2col) from the field,
;              wiping whatever glyph block was stamped over them.
;   uses: a, x, y, trow, tcol
; ------------------------------------------------------------
restore2x2
        lda g2row
        sta trow
        lda g2col
        sta tcol
        jsr drawfieldcell
        lda g2row
        sta trow
        lda g2col
        clc
        adc #1
        sta tcol
        jsr drawfieldcell
        lda g2row
        clc
        adc #1
        sta trow
        lda g2col
        sta tcol
        jsr drawfieldcell
        lda g2row
        clc
        adc #1
        sta trow
        lda g2col
        clc
        adc #1
        sta tcol
        jsr drawfieldcell
        rts

; ------------------------------------------------------------
; spawnexplosion   start a burst at tile (trow,tcol). silently
;                  does nothing if all 4 slots are busy - a
;                  missing burst is better than a missing tank.
;   uses: a, x, and everything draw2x2 uses
; ------------------------------------------------------------
spawnexplosion
        lda trow              ; a 2x2 block at row 24 would write rows 24
        cmp #24               ; AND 25, and the screen row tables only go
        bcc @rowok            ; to 24 - index 25 reads past the end and
        lda #23               ; lands near the TOP of the screen, which
        sta trow              ; is where the bottom half of a burst at
@rowok  lda tcol              ; the base was turning up. same for the
        cmp #25               ; last column.
        bcc @colok
        lda #24
        sta tcol
@colok  ldx #0
@f      lda extim,x
        beq @got
        inx
        cpx #4
        bne @f
        rts
@got    lda trow
        sta exrows,x
        lda tcol
        sta excols,x
        lda #expltime
        sta extim,x
        lda trow
        sta g2row
        lda tcol
        sta g2col
        lda #explchr1
        sta gbase
        lda #7                ; yellow flash
        sta gcol
        jsr draw2x2
        rts

; ------------------------------------------------------------
; updateexplosions   age every burst: swap to the second frame
;                    half way through, and redraw the field
;                    underneath when it expires.
;   uses: a, x, extmp, and everything draw2x2/restore2x2 use
; ------------------------------------------------------------
updateexplosions
        ldx #0
@lp     lda extim,x
        beq @next
        dec extim,x
        lda extim,x
        beq @gone
        cmp #explhalf
        bne @next
        stx extmp
        lda exrows,x
        sta g2row
        lda excols,x
        sta g2col
        lda #explchr2
        sta gbase
        lda #2                ; red as it dies down
        sta gcol
        jsr draw2x2
        ldx extmp
        jmp @next
@gone   stx extmp
        lda exrows,x
        sta g2row
        lda excols,x
        sta g2col
        jsr restore2x2
        lda #1                ; restore2x2 paints from the FIELD, which
        sta exrepaint         ; knows nothing about anything drawn on
        ldx extmp              ; top of it - a power-up under a burst
@next   inx                    ; came back as blank floor while still
        cpx #4                 ; being flagged active and collectable
        bne @lp
        lda exrepaint
        beq @done
        lda #0
        sta exrepaint
        jsr repaintoverlays
@done   rts

; ------------------------------------------------------------
; repaintoverlays   put back the things that live on the screen
;                   but not in the field buffer: the power-up and
;                   the arrival marker. anything that restores a
;                   cell from the field has to call this after.
;   uses: a, x, y
; ------------------------------------------------------------
repaintoverlays
        lda pwactive
        beq @star
        lda pwphase           ; not while it is in the dark half of its
        bne @star             ; end-of-life blink
        jsr drawpowerup
@star   lda staractive
        beq @done
        lda starrow
        sta g2row
        lda starcol
        sta g2col
        lda #spawnchr
        sta gbase
        lda #1
        sta gcol
        jsr draw2x2single
@done   rts

; ------------------------------------------------------------
; boomat   convenience: burst at enemy x's current position.
;   in:   x = enemy index; x is NOT preserved
; ------------------------------------------------------------
boomat  stx extmp2
        lda mox,x
        jsr xtotile
        bcc @no
        sta tcol
        ldx extmp2
        lda moy,x
        jsr ytotile
        bcc @no
        sta trow
        jsr spawnexplosion
@no     ldx extmp2
        rts

; ------------------------------------------------------------
; cellclear2x2   are all 4 field cells at (trow,tcol) floor?
;   out:  carry set = clear. trow/tcol restored either way.
;   uses: a, x, y, cc2r, cc2c
; ------------------------------------------------------------
; itemnearplayer   would an item at (trow,tcol) sit under or right
;                  beside a player's tank - within 8px of it?
;   out:  carry set = too close
;   uses: a, pwx, pwy
; ------------------------------------------------------------
itemnearplayer
        lda tcol              ; the item's box, in the tanks' pixels
        asl
        asl
        asl
        clc
        adc #24
        sta pwx
        lda trow
        asl
        asl
        asl
        clc
        adc #50
        sta pwy
        lda p1alive
        beq @p2
        lda p1x
        sec
        sbc pwx
        jsr dabs
        cmp #24               ; 16 would be touching; 24 leaves a gap
        bcs @p2
        lda p1y
        sec
        sbc pwy
        jsr dabs
        cmp #24
        bcc @near
@p2     lda p2alive
        beq @clear
        lda p2x
        sec
        sbc pwx
        jsr dabs
        cmp #24
        bcs @clear
        lda p2y
        sec
        sbc pwy
        jsr dabs
        cmp #24
        bcc @near
@clear  clc
        rts
@near   sec
        rts

; ------------------------------------------------------------
cellclear2x2
        lda trow
        sta cc2r
        lda tcol
        sta cc2c
        jsr tileat
        bne @no
        inc tcol
        jsr tileat
        bne @no
        inc trow
        jsr tileat
        bne @no
        dec tcol
        jsr tileat
        bne @no
        lda cc2r
        sta trow
        lda cc2c
        sta tcol
        sec
        rts
@no     lda cc2r
        sta trow
        lda cc2c
        sta tcol
        clc
        rts

; ------------------------------------------------------------
; trypowerup   roll for a power-up and place it on a clear 2x2
;              patch of floor. only one is ever on the field.
;              the 1-in-4 "nothing" result keeps the drop from
;              being clockwork.
;   uses: a, x, y, trow, tcol, pwtmp
; ------------------------------------------------------------
trypowerup
        lda pwactive          ; only one item exists at a time - a new
        beq @none             ; one wipes the old, as in the original
        lda pwrow
        sta g2row
        lda pwcol
        sta g2col
        jsr restore2x2
        lda #0
        sta pwactive
@none   jsr rand256
        and #7                ; 6 types, reroll on 6 or 7
        cmp #6
        bcs @none
        sta pwtype
        lda #8                ; 8 attempts at a clear spot, then give up
        sta pwtmp
@try    jsr rand256
        and #15
        clc
        adc #4                ; rows 4-19: clear of the entry lanes at
        sta trow              ; the top and the nest at the bottom
        jsr rand256
        and #15
        clc
        adc #4
        sta tcol
        jsr cellclear2x2
        bcc @retry
        jsr itemnearplayer    ; and not under, or touching, a player's
        bcc @place            ; tank: it used to land underneath and be
@retry  dec pwtmp             ; taken before anyone saw it
        bne @try
@no     rts
@place  lda trow
        sta pwrow
        lda tcol
        sta pwcol
        lda #1
        sta pwactive
        lda #pwlifeset        ; items do not wait forever
        sta pwlife
        lda #0
        sta pwphase
        jsr drawpowerup
        rts

; ------------------------------------------------------------
; drawpowerup   stamp the current power-up's glyph block.
; ------------------------------------------------------------
drawpowerup
        lda pwrow
        sta g2row
        lda pwcol
        sta g2col
        ldx pwtype
        lda pwglyph,x
@have   sta gbase
        lda #1                ; white - stands out on the grey floor
        sta gcol
        jsr draw2x2
        rts

; ------------------------------------------------------------
; updatepowerup   has either player driven over it?
;   uses: a, chkx, chky, chkx2, chky2, and boxesoverlap
; ------------------------------------------------------------
updatepowerup
        lda pwactive
        bne @on
        rts
@on     lda pwlife            ; nearly out of time? blink it, so it is
        cmp #pwflash          ; clear the chance is about to go rather
        bcs @noflash          ; than the item just vanishing
        lda tick
        lsr a
        lsr a
        lsr a
        and #1
        cmp pwphase
        beq @noflash
        sta pwphase           ; only redraw on the turn of the blink
        cmp #0                ; sta leaves the flags alone, so re-test
        bne @hide              ; the phase itself rather than the cmp
        jsr drawpowerup        ; above, which is never equal here
        jmp @noflash
@hide   lda pwrow
        sta g2row
        lda pwcol
        sta g2col
        jsr restore2x2
@noflash     lda pwcol             ; tile -> pixel box, same 16x16 as a tank
        asl a
        asl a
        asl a
        clc
        adc #24
        sta chkx
        lda pwrow
        asl a
        asl a
        asl a
        clc
        adc #50
        sta chky
        lda p1alive
        beq @p2
        lda p1x
        sta chkx2
        lda p1y
        sta chky2
        jsr boxesoverlap
        bcc @p2
        lda #0
        sta pwtaker
        jmp @take
@p2     lda p2alive
        beq @done
        lda p2x
        sta chkx2
        lda p2y
        sta chky2
        jsr boxesoverlap
        bcc @done
        lda #1
        sta pwtaker
        jmp @take             ; (this jump was missing: player 2 touched
                               ; the item, was noted as the taker, and
                               ; nothing happened)
@done   rts
@take   lda #0
        sta pwactive
        lda pwrow
        sta g2row
        lda pwcol
        sta g2col
        jsr restore2x2
        jsr applypowerup
        rts

; ------------------------------------------------------------
; applypowerup   dispatch on the collected type.
; ------------------------------------------------------------
applypowerup
        jsr bonusscore        ; every pickup is worth 500
        lda pwtype
        cmp #0
        bne @s1
        jmp dostrike
@s1     cmp #1
        bne @s2
        jmp doshovel
@s2     cmp #2
        bne @s3
        jmp dowatch
@s3     cmp #3
        bne @s4
        jmp dotank
@s4     cmp #4
        bne @s5
        jmp dohelmet
@s5     jmp dostar

; ------------------------------------------------------------
; dotank    an extra life for whoever picked it up.
; ------------------------------------------------------------
dotank  lda pwtaker
        bne @p2
        lda p1lives           ; the panel shows one digit: nine at most,
        cmp #9                ; or a tenth life would draw as a colon
        bcs @done
        inc p1lives
        jmp @done
@p2     lda p2lives
        cmp #9
        bcs @done
        inc p2lives
@done   jsr marksidebar
        rts

; ------------------------------------------------------------
; dohelmet  a shield on the collecting player for a while.
;           hittank1/hittank2 check it before taking a life.
; ------------------------------------------------------------
dohelmet
        lda pwtaker
        bne @p2
        lda #helmetset
        sta p1shield
        rts
@p2     lda #helmetset
        sta p2shield
        rts

; ------------------------------------------------------------
; dostar    upgrade the collecting player's gun, to a ceiling.
;           level 1 doubles shell speed (the bullet is stepped
;           twice a tick rather than the step being rewritten);
;           level 2 lets shells break steel as well as brick.
; ------------------------------------------------------------
dostar  lda pwtaker
        bne @p2
        lda p1star
        cmp #maxstar
        bcs @done
        inc p1star
        jmp @done
@p2     lda p2star
        cmp #maxstar
        bcs @done
        inc p2star
@done   jsr marksidebar       ; applypowerup redraws the sidebar BEFORE
        rts                    ; dispatching, so without this the new pip
                                ; did not appear until something else
                                ; happened to trigger a redraw

; ------------------------------------------------------------
; bonusscore   add 500 to the score, in bcd like addscore.
; ------------------------------------------------------------
bonusscore
        lda #$05              ; 500 for the pickup, to whoever took it
        ldy pwtaker
        jsr addhundreds
        jsr marksidebar
        rts

; ------------------------------------------------------------
; dogrenade   destroy every enemy tank on the field outright -
;             armour included, so it does not merely wound the
;             armoured ones - with a burst and score for each.
;   uses: a, x, gtmp
; ------------------------------------------------------------
dostrike
        lda pwtaker           ; the kills are the caller's: addscore
        sta strikeby          ; credits 'killer', which was still whoever
        lda #1                ; fired the last shell
        sta strikeon          ; the drones come in from the top of the
                               ; field and take the tanks as they reach
        lda #dfminy           ; them: the tanks nearest the top go first
        sta strikey
        lda #6                ; hold the tanks still while it happens
        sta freezetimer       ; (about a second, in 8-tick units)
        rts

; ------------------------------------------------------------
; updatestrike   the drone strike, a tick at a time: the dive
;                line comes down the field, and every tank it
;                reaches is destroyed. called every tick.
;   uses: a, x, gtmp
; ------------------------------------------------------------
updatestrike
        lda strikeon
        bne @on
        rts
@on     lda strikey           ; the dive comes down fast
        clc
        adc #strikespeed
        sta strikey
        ldx #0
@lp     lda moactive,x        ; every tank the line has reached
        beq @next
        lda moy,x
        cmp strikey
        bcs @next
        lda #0
        sta moactive,x
        stx gtmp
        jsr boomat
        lda strikeby          ; to whoever called the strike in
        sta killer
        ldx gtmp
        jsr addscore
        jsr playexplosion
        ldx gtmp
@next   inx
        cpx #4
        bne @lp
        lda strikey           ; past the bottom: the strike is over
        cmp #dfmaxy+16
        bcc @more
        lda #0
        sta strikeon
        jmp checkwaveclear
@more   rts

; ------------------------------------------------------------
; doshovel   turn the brick nest round the base to steel for a
;            while. steel cannot be shot through at all, so this
;            is a real reprieve rather than just thicker brick.
;            updatetimers puts it back.
; ------------------------------------------------------------
doshovel
        lda #shieldset
        sta shieldtimer
        lda #2
        jsr setnest
        rts

; ------------------------------------------------------------
; dowatch   freeze the tanks. bullets already in flight keep
;           going - it stops the tanks, not time itself.
; ------------------------------------------------------------
dowatch lda #freezeset
        sta freezetimer
        rts

; ------------------------------------------------------------
; setnest   set every cell of the base's nest to a (1 brick,
;           2 steel) and redraw it, leaving the eagle itself
;           alone. the nest is rows 20-23, cols 10-15; the base
;           occupies rows 22-23, cols 12-13 inside it.
;   uses: a, x, y, trow, tcol, nestval
; ------------------------------------------------------------
setnest sta nestval2
        lda #baserow-2        ; two layers above and either side
        sta nesttop
        lda #baserow
        sta basetop
        lda nestval2
        jsr buildnest
        lda #baserow-2        ; redraw the band we just changed.
        sta trow              ; BOTH counters live in memory:
        lda #0                ; drawfieldcell uses x AND y, so either
        sta nestr             ; one kept in a register is destroyed on
@dr     lda #basecol-2        ; the first call and the loop never ends -
        sta tcol              ; which hung the game outright
        lda #0
        sta nestc
@dc     jsr drawfieldcell
        inc tcol
        inc nestc
        lda nestc
        cmp #6
        bne @dc
        inc trow
        inc nestr
        lda nestr
        cmp #4
        bne @dr
        rts

; ------------------------------------------------------------
; updatetimers   age the two timed power-ups. both are counted in
;                units of 8 ticks, so a byte covers 40 seconds.
;   uses: a, x, y
; ------------------------------------------------------------
updatetimers
        inc pwtick
        lda pwtick
        and #7
        beq @tick
        rts
@tick   lda p1shield
        beq @s2t
        dec p1shield
@s2t    lda p2shield
        beq @fz
        dec p2shield
@fz     lda freezetimer
        beq @pw
        dec freezetimer
@pw     lda pwactive          ; an uncollected item times out. this
        beq @sh                ; needs its own entry: hanging it off the
                                ; freeze branch above meant it only ran
                                ; while a watch was active, which is
                                ; almost never
        lda pwlife
        beq @sh
        dec pwlife
        bne @sh
        lda pwrow
        sta g2row
        lda pwcol
        sta g2col
        jsr restore2x2
        lda #0
        sta pwactive
@sh     lda shieldtimer
        beq @done
        dec shieldtimer
        bne @done
        lda #brickfull        ; shield over - back to brick
        jsr setnest
@done   rts

; ------------------------------------------------------------
; updaterespawn   count each dead player back in. while the timer
;                 runs the tank is off the field entirely - no
;                 sprite, no movement, no firing, and nothing can
;                 hit it again. on return it gets a short shield,
;                 because a spawn point is exactly where an enemy
;                 shell is likely to be heading.
;   uses: a, x, y
; ------------------------------------------------------------
updaterespawn
        lda p1respawn
        beq @p2
        dec p1respawn
        bne @p2
        jsr respawnp1         ; onto the spawn point...
        ldx #0
        jsr spawnfree         ; ...but only if nothing is standing there.
        bcs @p1in             ; enemies already rechecked their spot
        lda #1                ; before hatching; players never did, and
        sta p1respawn         ; a player could reappear inside a tank
        jmp @p2               ; parked on their spawn. wait a tick.
@p1in   lda d015
        ora #%00000001
        sta d015
        lda #respawnmercy
        sta p1shield
@p2     lda p2respawn
        beq @done
        dec p2respawn
        bne @done
        jsr respawnp2
        ldx #1
        jsr spawnfree
        bcs @p2in
        lda #1
        sta p2respawn
        jmp @done
@p2in   lda d015
        ora #%00000010
        sta d015
        lda #respawnmercy
        sta p2shield
@done   rts

; ------------------------------------------------------------
; updateextras   everything in this stage, once per tick.
; ------------------------------------------------------------
updateextras
        jsr rotatehunter
        jsr updaterespawn
        jsr updatespawnstar
        jsr updateexplosions
        jsr updatepowerup
        jsr updatestrike
        jsr updatetimers
        rts

; ------------------------------------------------------------
; resetextras   clear all of it - called when a round starts and
;               whenever the field is redrawn under it.
;   uses: a, x
; ------------------------------------------------------------
resetextras
        lda #0                ; NOTE: p1star/p2star are deliberately not
        sta pwactive          ; cleared here. this runs at every wave
        sta pwtaker           ; change as well as at the start of a
        sta p1shield          ; game, and the gun upgrade is earned -
        sta p2shield          ; only being shot takes it away. setupgame
        sta freezetimer
        sta shieldtimer
        sta strikeon          ; no strike carries into a new field
        sta pwtick
        ldx #0
@lp     lda #0
        sta extim,x
        inx
        cpx #4
        bne @lp
        rts

; ==============================================================
; STAGE 8: user-defined characters
; ==============================================================
;   the playfield was drawn with rom characters - bricks and steel
;   were both reversed-space (160) told apart only by colour, and
;   the base was character 8, which is not an eagle by any stretch.
;
;   the vic can only take a whole 2k character set, not individual
;   glyphs, so initchars copies the rom set into ram at $3800 and
;   then overwrites the handful of codes the playfield uses. the
;   copy is what keeps the sidebar, title screen and score legible -
;   they are all still ordinary rom letters and digits.
;
;   $3800 is free: the program itself ends at $313e and the sprite
;   data runs to $3140, so the 2k from $3800 to $3fff is untouched
;   ram inside vic bank 0.
;
;   glyph codes are taken from the graphics half of the set, well
;   clear of the letters (1-26), digits (48-57) and punctuation the
;   text uses:
;     96      brick
;     97      steel
;     98-101  the eagle, as a 2x2 block: tl tr bl br
; ------------------------------------------------------------
charbase = $4800
brickchr = 96
; a brick cell is four quarters, and a shell takes the half facing it.
; the live field stores brick as $10 + a four-bit mask of the quarters
; still standing: bit0 top-left, bit1 top-right, bit2 bottom-left,
; bit3 bottom-right. so a whole brick is $1f, and shooting it twice
; from two different sides leaves a single corner before it goes.
; values 0/2/3 (floor, steel, base) are untouched, and the level
; format's own 1/4/5/6 never reach the live field - readlevel turns
; brick into brickfull and the spawn markers into floor.
brickmask = $10
brickfull = $1f
armrmask  = $20          ; armoured wall, same quarter mask. damage
halftop   = $fe          ; markers for the half blocks: never stored
halfbottom = $fd         ; in the field, only passed to stampblock
armrfull  = $2f          ; never creates these - only the level does
riverchr = 142
forestchr = 143
icechr   = 144
spawnchr = 149           ; two frames, pulsing
minitank = 155           ; one cell, for the reserve count
pipstar  = 156           ; a real star for the sidebar pips. they
                          ; used to borrow the power-up icon's
                          ; top-left cell, which is a corner of
                          ; its rounded frame - not a star at all
wreckchr = 151           ; the base after it is hit: a mushroom
                          ; cloud. deliberately
                          ; ASYMMETRIC: the first attempt mirrored
                          ; left to right, and any mirrored 16x16
                          ; shape with paired features reads as a
                          ; face - that one had ears, eyes and a
                          ; mouth. a heap with its peak off-centre
                          ; does not.
armrhalf = 145           ; +0 top, +1 bottom, +2 left, +3 right
tileriver  = 8           ; stops tanks; shells fly over
tileforest = 9           ; stops nothing; hides what drives through
tileice    = 10          ; stops nothing; tanks slide on it
steelchr = 97
hqchr    = 98            ; the base: a radiation trefoil - each
                          ; side is defending a reactor            ; +0 tl, +1 tr, +2 bl, +3 br

; ------------------------------------------------------------
; initchars   copy the rom character set to $3800, install the
;             custom glyphs over it, and point the vic at it.
;             called once from start, before interrupts are
;             enabled.
;   uses: a, x, y, lvlptr, dstptr
;   note: the character rom is only visible at $d000 with the i/o
;         area banked out ($01 = $33). while it is banked out the
;         vic/sid/cia registers are NOT reachable, so this must
;         run with interrupts off - our own irq handler touches
;         $d019 on entry and would read the character rom
;         instead. start does sei before calling this.
; ------------------------------------------------------------
initchars
        lda $01
        pha
        lda #$33              ; ram + char rom, i/o banked out
        sta $01
        lda #$00
        sta lvlptr
        lda #$d0
        sta lvlptr+1
        lda #<charbase
        sta dstptr
        lda #>charbase
        sta dstptr+1
        ldx #8                ; the whole rom set: bank 1 has room
@pg     ldy #0
@by     lda (lvlptr),y
        sta (dstptr),y
        iny
        bne @by
        inc lvlptr+1
        inc dstptr+1
        dex
        bne @pg
        pla
        sta $01               ; i/o back on before touching the vic

        ldx #0                ; install the custom glyphs
@clp    lda customglyphs,x
        sta charbase+brickchr*8,x
        inx
        bne @clp
        ldx #0                ; ...and the 80 bytes past the 256 mark
@clp2   lda customglyphs+256,x
        sta charbase+brickchr*8+256,x
        inx
        cpx #232
        bne @clp2
                               ; codes 96-150: brick, armour, eagle,
                               ; 2 explosion frames, 6 power-ups. 304
                               ; bytes overflows a byte counter, hence
                               ; the two loops.
        ldx #0                ; the font: letters at codes 1-26
@flp    lda fontletters,x
        sta charbase+1*8,x
        inx
        cpx #208
        bne @flp
        ldx #0                ; the punctuation the screens actually
@slp    lda fontstar,x        ; use: star 42, dash 45, ampersand 38
        sta charbase+42*8,x
        lda fontdash,x
        sta charbase+45*8,x
        lda fontamp,x
        sta charbase+38*8,x
        inx
        cpx #8
        bne @slp
        ldx #0                ; digits 0-9 and the colon, codes 48-58
@dlp    lda fontdigits,x
        sta charbase+48*8,x
        inx
        cpx #88
        bne @dlp

        lda #%00010010        ; screen at $4400 (offset $400 -> 1<<4),
        sta $d018              ; charset at $4800 (offset $800 -> 1<<1)
        rts

; ------------------------------------------------------------
; the glyphs themselves, in code order from brickchr.
; ------------------------------------------------------------

; ------------------------------------------------------------
; the font. 6x7 in an 8x8 cell, so glyphs have a clear pixel of
; gap on the right and one blank row underneath. only the codes
; the game actually prints are replaced - the rest of the copied
; rom set is left alone.
; ------------------------------------------------------------
fontletters
        ; screen codes 1-26, A-Z
        ; 'A'
        byte %01101100
        byte %11000110
        byte %11000110
        byte %11101110
        byte %11000110
        byte %11000110
        byte %11000110
        byte %00000000
        ; 'B'
        byte %11101100
        byte %11000110
        byte %11000110
        byte %11101100
        byte %11000110
        byte %11000110
        byte %11101100
        byte %00000000
        ; 'C'
        byte %01101100
        byte %11000110
        byte %11000000
        byte %11000000
        byte %11000000
        byte %11000110
        byte %01101100
        byte %00000000
        ; 'D'
        byte %11101100
        byte %11000110
        byte %11000110
        byte %11000110
        byte %11000110
        byte %11000110
        byte %11101100
        byte %00000000
        ; 'E'
        byte %11101110
        byte %11000000
        byte %11000000
        byte %11101100
        byte %11000000
        byte %11000000
        byte %11101110
        byte %00000000
        ; 'F'
        byte %11101110
        byte %11000000
        byte %11000000
        byte %11101100
        byte %11000000
        byte %11000000
        byte %11000000
        byte %00000000
        ; 'G'
        byte %01101100
        byte %11000110
        byte %11000000
        byte %11011110
        byte %11000110
        byte %11000110
        byte %01101100
        byte %00000000
        ; 'H'
        byte %11000110
        byte %11000110
        byte %11000110
        byte %11101110
        byte %11000110
        byte %11000110
        byte %11000110
        byte %00000000
        ; 'I'
        byte %11101110
        byte %00111000
        byte %00111000
        byte %00111000
        byte %00111000
        byte %00111000
        byte %11101110
        byte %00000000
        ; 'J'
        byte %11101110
        byte %00011000
        byte %00011000
        byte %00011000
        byte %11011000
        byte %11011000
        byte %01111000
        byte %00000000
        ; 'K'
        byte %11000110
        byte %11001100
        byte %11011000
        byte %11110000
        byte %11011000
        byte %11001100
        byte %11000110
        byte %00000000
        ; 'L'
        byte %11000000
        byte %11000000
        byte %11000000
        byte %11000000
        byte %11000000
        byte %11000000
        byte %11101110
        byte %00000000
        ; 'M'
        byte %11000110
        byte %11101110
        byte %11010110
        byte %11010110
        byte %11000110
        byte %11000110
        byte %11000110
        byte %00000000
        ; 'N'
        byte %11000110
        byte %11100110
        byte %11010110
        byte %11001110
        byte %11000110
        byte %11000110
        byte %11000110
        byte %00000000
        ; 'O'
        byte %01101100
        byte %11000110
        byte %11000110
        byte %11000110
        byte %11000110
        byte %11000110
        byte %01101100
        byte %00000000
        ; 'P'
        byte %11101100
        byte %11000110
        byte %11000110
        byte %11101100
        byte %11000000
        byte %11000000
        byte %11000000
        byte %00000000
        ; 'Q'
        byte %01101100
        byte %11000110
        byte %11000110
        byte %11000110
        byte %11010110
        byte %11001100
        byte %01101110
        byte %00000000
        ; 'R'
        byte %11101100
        byte %11000110
        byte %11000110
        byte %11101100
        byte %11011000
        byte %11001100
        byte %11000110
        byte %00000000
        ; 'S'
        byte %01101100
        byte %11000110
        byte %11000000
        byte %01101100
        byte %00000110
        byte %11000110
        byte %01101100
        byte %00000000
        ; 'T'
        byte %11101110
        byte %00111000
        byte %00111000
        byte %00111000
        byte %00111000
        byte %00111000
        byte %00111000
        byte %00000000
        ; 'U'
        byte %11000110
        byte %11000110
        byte %11000110
        byte %11000110
        byte %11000110
        byte %11000110
        byte %01101100
        byte %00000000
        ; 'V'
        byte %11000110
        byte %11000110
        byte %11000110
        byte %11000110
        byte %01101100
        byte %00111000
        byte %00111000
        byte %00000000
        ; 'W'
        byte %11000110
        byte %11000110
        byte %11000110
        byte %11010110
        byte %11010110
        byte %11101110
        byte %11000110
        byte %00000000
        ; 'X'
        byte %11000110
        byte %01101100
        byte %00111000
        byte %00111000
        byte %00111000
        byte %01101100
        byte %11000110
        byte %00000000
        ; 'Y'
        byte %11000110
        byte %01101100
        byte %00111000
        byte %00111000
        byte %00111000
        byte %00111000
        byte %00111000
        byte %00000000
        ; 'Z'
        byte %11101110
        byte %00001100
        byte %00011000
        byte %00110000
        byte %01100000
        byte %11000000
        byte %11101110
        byte %00000000

fontamp                        ; "&", in the font's own 6x7 style
        byte %01100000
        byte %10010000
        byte %10100000
        byte %01000000
        byte %10101000
        byte %10010000
        byte %01101000
        byte %00000000
fontstar
        ; screen code 42 - the menu cursor, an arrow
        ; '*'
        byte %00100000
        byte %00110000
        byte %00111000
        byte %00111100
        byte %00111000
        byte %00110000
        byte %00100000
        byte %00000000

fontdash
        ; screen code 45
        ; '-'
        byte %00000000
        byte %00000000
        byte %00000000
        byte %11101110
        byte %00000000
        byte %00000000
        byte %00000000
        byte %00000000

fontdigits
        ; screen codes 48-58, 0-9 and colon
        ; '0'
        byte %01101100
        byte %11000110
        byte %11001110
        byte %11010110
        byte %11100110
        byte %11000110
        byte %01101100
        byte %00000000
        ; '1'
        byte %00111000
        byte %01111000
        byte %00111000
        byte %00111000
        byte %00111000
        byte %00111000
        byte %11101110
        byte %00000000
        ; '2'
        byte %01101100
        byte %11000110
        byte %00001110
        byte %00111000
        byte %01100000
        byte %11000000
        byte %11101110
        byte %00000000
        ; '3'
        byte %11101110
        byte %00001100
        byte %00111000
        byte %00011000
        byte %00000110
        byte %11000110
        byte %01101100
        byte %00000000
        ; '4'
        byte %00011100
        byte %00111100
        byte %01101100
        byte %11001100
        byte %11101110
        byte %00001100
        byte %00001100
        byte %00000000
        ; '5'
        byte %11101110
        byte %11000000
        byte %11101100
        byte %00000110
        byte %00000110
        byte %11000110
        byte %01101100
        byte %00000000
        ; '6'
        byte %00110110
        byte %01100000
        byte %11000000
        byte %11101100
        byte %11000110
        byte %11000110
        byte %01101100
        byte %00000000
        ; '7'
        byte %11101110
        byte %00001100
        byte %00011000
        byte %00110000
        byte %00110000
        byte %00110000
        byte %00110000
        byte %00000000
        ; '8'
        byte %01101100
        byte %11000110
        byte %11000110
        byte %01101100
        byte %11000110
        byte %11000110
        byte %01101100
        byte %00000000
        ; '9'
        byte %01101100
        byte %11000110
        byte %11000110
        byte %01101110
        byte %00000110
        byte %00001100
        byte %01110000
        byte %00000000
        ; ':'
        byte %00000000
        byte %00111000
        byte %00111000
        byte %00000000
        byte %00111000
        byte %00111000
        byte %00000000
        byte %00000000

; ------------------------------------------------------------
; decodetile   classify one field byte (0-3, post-normalisation)
;   in:   a = field value (0=floor 1=brick 2=steel 3=base)
;   out:  a = screen code, outcol = colour ram value
; ------------------------------------------------------------
decodetile
        sta tiletmp
        cmp #armrmask         ; $20-$2f armour, $10-$1f brick
        bcc @notarmour
        jmp @armour
@notarmour
        cmp #brickmask
        bcc @whole
        jmp @half
@whole  cmp #tileriver
        bne @notriver
        lda #14               ; light blue
        sta outcol
        lda #riverchr
        rts
@notriver
        cmp #tileforest
        bne @notforest
        lda #5                ; green
        sta outcol
        lda #forestchr
        rts
@notforest
        cmp #tileice
        bne @notice
        lda #1                ; white
        sta outcol
        lda #icechr
        rts
@notice cmp #1
        beq @brick
        cmp #2
        beq @steel
        cmp #3
        beq @base
        lda #0
        sta outcol
        lda #32
        rts
@brick  lda #9
        sta outcol
        lda #brickchr
        rts
@armour lda #15               ; armour, whole or a placed half
        sta outcol
        lda tiletmp
        and #15
        cmp #15
        bne @armrhalf
        lda #steelchr
        rts
@armrhalf
        tax
        lda armrglyph,x
        rts
@half   lda #9                ; damaged brick - the glyph follows the
        sta outcol             ; mask of quarters still standing
        lda tiletmp
        and #15
        tax
        lda brickglyph,x
        rts
@steel  lda #15              ; light grey - kept distinct from the
        sta outcol            ; medium-grey background (both are grey,
        lda #steelchr          ; but different shades) so steel walls
        rts                     ; don't visually vanish into the floor
@base   lda #0                ; every reactor is black, in every mode
        sta outcol
        lda rowbuf            ; which base is this? a duel has one at
        cmp #3                ; each end, and the quadrant has to be
        bcs @ownbase          ; measured from THAT base's own top row.
        lda #duelbaserow      ; the top one's corner is row 0. measuring
        jmp @havetop          ; from baserow gave (0-23)*2 = -46, so it
@ownbase                       ; drew characters 52-55: the digits 4-7
        lda #baserow
@havetop
        sta basetmp
        lda rowbuf
        sec
        sbc basetmp
        asl a
        sta tmpq
        lda colbuf
        sec
        sbc #basecol
        clc
        adc tmpq
        clc
        adc #hqchr
        rts

; ---- variables -------------------------------------------
tick    byte 0
videostd byte 0
rowbuf  byte 0
colbuf  byte 0
outcol  byte 0
tmpq    byte 0
tiletmp byte 0
mullo   byte 0
mulhi   byte 0
p1x     byte 0
p1y     byte 0
p1xmsb  byte 0
p2x     byte 0
p2y     byte 0
p2xmsb  byte 0

; ---- stage 2 movement variables ----------------------------
p1facing byte 0
p2facing byte 0
cjoy    byte 0
cx      byte 0
cy      byte 0
cfacing byte 0
creq    byte 255
trow2   byte 0
tcol2   byte 0
pv1     byte 0
pv2     byte 0
sev1    byte 0
bmask   byte 0
cpend   byte 255
cslide  byte 0
ctravel byte 0
cturn   byte 0
p1anim  byte 0
p2anim  byte 0
p1step  byte 0
p2step  byte 0
p1turn  byte 0
p2turn  byte 0
ecool   byte 0,0,0,0
p1travel byte 0
p2travel byte 0
etravel byte 0,0,0,0
p1slide byte 0
p2slide byte 0
eslide  byte 0,0,0,0
p1pend  byte 255
p2pend  byte 255
epend   byte 255,255,255,255
oldcx   byte 0
oldcy   byte 0
; multi-tank overlap list: every OTHER tank's box, for whichever
; tank is about to move - see buildotherlist_p1/p2/enemy. up to
; 5 entries (the other player + up to 4 enemies, or both players
; + up to 3 other enemies).
otherboxx byte 0,0,0,0,0
otherboxy byte 0,0,0,0,0
othercount byte 0
selfidx byte 0
tmpx    byte 0
tmpy    byte 0
trow    byte 0
tcol    byte 0

; ---- stage 3 bullet/base variables -------------------------
p1spawnx byte 0
p1spawny byte 0
p2spawnx byte 0
p2spawny byte 0
bactive byte 0
bx      byte 0
by      byte 0
bdir    byte 0

; ---- stage 4 lives / game-state variables ------------------
p1lives byte 3

; ---- stage 6 scoring / wave variables -----------------------
score   byte 0,0,0,0,0,0      ; two 3-byte bcd scores: player 1 at
                               ; score+0..2, player 2 at score+3..5.
                               ; a two-player game used to pool both
                               ; players' kills into one total, so
                               ; neither could tell what they had done -
                               ; and the stage bonus for outscoring the
                               ; other player had nothing to compare.
addtmp  byte 0
wave    byte 1
basemovetimer byte 60
basefiretimer byte 150
p2lives byte 3
p1alive byte 1
p2alive byte 1
gameover byte 0
gameoverdrawn byte 0
sidebardirty byte 0
gorelease byte 0
gowait  byte 0
hiscore byte 0,0,0
hitmp   byte 0,0,0
attridx byte 0
attrtimer byte 1
atmp    byte 0
atmp2   byte 0
inattract byte 0
attridle byte 0
attrarmed byte 0
attrpre byte 0
startstage byte 1
stgdig  byte 0
gaveup  byte 0
loopno  byte 0
hunterslot byte 0
huntertimer byte 0
mixleft byte 0,0,0,0
spawnlist byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0            ; bcd, survives between games
wavewait byte 0
bantmp  byte 0
bandig  byte 0
pipwho  byte 0
pipn    byte 0
scoreof byte 0
rsvi    byte 0
exrepaint byte 0
scrfine byte 7
scrphase byte 0
scrbuf  byte 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
movephase byte 0
blkn    byte 0
dbrow   byte 0
basetmp byte 0
duelmode byte 0
winner  byte 0
endgame byte 0
nobodywins byte 0
stamptop byte 0
stampbot byte 0
endwait byte 0,0          ; the ending's countdown to the title
endtimer byte 0
endsub  byte 0            ; ticks to the next count of endtimer
misy    byte 0
sirdir  byte 0
sirfreq byte 0,0
wreckrow byte 23
wreckshown byte 0
flashcol byte 0

blkval  byte 0
scorecol byte 1
pfbest  byte 0
pfbestd byte 0
pfd     byte 0
pftmp   byte 0
staractive byte 0
startimer byte 0
starrow byte 0
starcol byte 0
pendslot byte 0

; ---- stage 7 title screen / mode select ---------------------
intitle byte 1
menusel byte 0
joy1prev byte $ff
nplayers byte 2
friendlyfire byte 0

; ---- stage 5 mob table (enemies 0-3, enemy bullets 4-7) ----
moactive byte 0,0,0,0,0,0,0,0
mox     byte 0,0,0,0,0,0,0,0
moy     byte 0,0,0,0,0,0,0,0
moptr   byte 0,0,0,0,0,0,0,0
mocol   byte 0,0,0,0,0,0,0,0
modir   byte 0,0,0,0,0,0,0,0
etype   byte 0,0,0,0
ehp     byte 0,0,0,0
emovetimer byte 0,0,0,0
eforcerand byte 0,0,0,0       ; force a random direction after a wedge
ehold   byte 0,0,0,0          ; ticks before it may turn straight back
ewant   byte 0                ; the direction it would like to take
eforced byte 0                ; this pick is a wedged tank's: no hold
efiretimer byte 0,0,0,0
etmpx   byte 0
prevmx  byte 0
prevmy  byte 0
chkx    byte 0
chky    byte 0
chkx2   byte 0
chky2   byte 0
stageleft byte 0              ; enemy tanks still to enter this stage
nextslot byte 0               ; which entry point gets the next one
spawntimer byte 0             ; paces arrivals
spawncount byte 0             ; total sent this stage - drives typecycle
freeslot byte 0               ; mob slot the next arrival will occupy
trys    byte 0                ; entry points left to try this tick
spx     byte 0
spy     byte 0
brtmpx  byte 0
; the three fixed entry points along the top of the field: left,
; centre and right, on field row 1 (row 0 is the steel border).
; pixel coords, matching mox/moy directly.
slotx   byte 24,120,216   ; columns 0, 12 and 24. the right one was
                           ; 208 = column 23, which left column 25
                           ; bare beside it - a tank is two columns
                           ; wide, so flush with the right edge is 24
sloty   byte 50,50,50
; which tank type each successive arrival is, cycled over 8 so a
; stage gets a mixed, repeating stream rather than one of each.
; enemy mix, 8 arrivals per row, indexed by wave (capped at row 3).
; wave 1 is basic tanks only - there is nothing to learn from an
; armoured tank on the first screen you ever see.
typehp    byte 1,1,1,4        ; heavy takes four hits; the rest one
typecol   byte 10,8,11,0      ; light red, orange, dark grey, black.
                               ; black is the four-hit heavy: the most
                               ; dangerous thing on the field reads as
                               ; the darkest.
                               ; chosen to clash with nothing: brown is
                               ; brick, light grey is armour, cyan the
                               ; river, green the forest, and the two
                               ; players own dark blue and yellow. light
                               ; green and light blue were rejected for
                               ; sitting next to the forest and player 2.
                               ; the light tank has been green (player
                               ; 2's colour) and light blue (the
                               ; river's) - cyan clashes with neither,
                               ; and light green was rejected for the
                               ; same reason green was: too close to
                               ; player 2 to tell apart mid-game.
ecooltab byte 26,26,16,26   ; reload per type - rapid-fire lives up
                          ; to its name; the rest match the player's 26
typescore byte $01,$02,$03,$04  ; bcd hundreds
; enemy mix, 8 arrivals a row. the first three stages ease you in;
; after that the row is chosen by which time round the 35 stages you
; are, and each loop drops the weakest type still present - so the
; maps repeat but what arrives on them does not.
        byte 0,0,1,0,0,1,0,0       ; stage 2: armoured cars appear
        byte 0,1,0,2,0,1,1,0       ; stage 3: rapid-fire appear
        byte 0,1,2,0,3,1,2,3       ; stages 4-35: all four types
        byte 1,2,1,3,2,1,3,2       ; loop 2 (36-70): no more light tanks
        byte 2,3,2,3,3,2,3,3       ; loop 3 (71-105): no armoured cars
        byte 3,3,3,3,3,3,3,3       ; loop 4 on: heavies, nothing else
prefdir byte 0
prefalt byte 255
cdtmp   byte 0
cdx     byte 0
cdsave  byte 0
; probability (out of 256) of taking computebasepref's direction
; rather than a fully random one, indexed by etype (0=basic
; 1=fast 2=armored, 4th entry unused but present for safety)
biasthresh byte 102,179,140,140

; ---- sprite draw-offset tables ------------------------------
; the tank art is 24x21 but the collision hitbox is 16x16; the
; visible hull sits at a different offset from the sprite's own
; (0,0) for each facing (turret+barrel occupy the rest of the
; canvas on the side facing travel). without correcting for
; this, the hardware sprite - drawn straight from cx/cy - visibly
; overlaps whatever is next to the hitbox instead of sitting
; inside it. indexed by facing (0=up 1=down 2=left 3=right),
; matching modir/p1facing/p2facing directly.
dirdx   byte 0,0,0,0
dirdy   byte 0,0,0,0
; bullets use one shared small-dot sprite regardless of
; direction, so their offset is a fixed constant, not a table.
bulletdx = 4
bulletdy = 10

; ---- row-offset lookup tables (compile-time constants) -----
; tileat/clearfieldcell/clearcell used to compute a row's byte
; offset with a loop that added 26 (or 40) once per row - up to
; 24 iterations, ~450 cycles, worst right when it mattered most
; (enemies converging on the base, near the highest row values).
; a tile/screen row's offset never changes, so it's just a table.
fieldrowlo byte 0,26,52,78,104,130,156,182,208,234,4,30,56,82,108,134,160,186,212,238,8,34,60,86,112
fieldrowhi byte 0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,2,2,2,2,2
screenrowlo byte 0,40,80,120,160,200,240,24,64,104,144,184,224,8,48,88,128,168,208,248,32,72,112,152,192
screenrowhi byte 0,0,0,0,0,0,0,1,1,1,1,1,1,2,2,2,2,2,2,2,3,3,3,3,3

; ---- (the old 3-band staging lists lived here; the sorted
; ---- multiplexer replaced them - see buildsprites) --------
; true double-buffered staging: within each zone, slots 0-3 =
; bank A, slots 4-7 = bank B. readbank says which half
; muxwritezone0/1/2 currently trust; classifymux always writes
; the other half, then flips readbank in a single atomic
; instruction. see classifymux.
; ---- sorted multiplexer state (see buildsprites) ------------
objx    byte 0,0,0,0,0,0,0,0,0,0,0,0     ; draw-corrected object positions
objy    byte 255,255,255,255,255,255,255,255,255,255,255,255
objp    byte 0,0,0,0,0,0,0,0,0,0,0,0
objc    byte 0,0,0,0,0,0,0,0,0,0,0,0
objpri  byte 0,0,0,0,0,0,0,0,0,0,0,0
sortorder byte 0,1,2,3,4,5,6,7,8,9,10,11   ; persistent across frames - initmux
                                  ; seeds it once and nothing resets it
dspy    byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0   ; display list, 2 banks of 8
dspx    byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
dspp    byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
dspc    byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
dsppri  byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
dspcnt  byte 0,0                 ; entries accepted, per bank
dspread byte 0                   ; bank the irq chain is reading
muxbank byte 0                   ; ...latched once a frame, so a flip
                                 ; mid-frame waits for the next one
dspwrite byte 0
dspoff  byte 0
cnt2    byte 0
cy2     byte 0
srcidx  byte 0
sidx2   byte 0
muxidx  byte 0                   ; next display entry the chain writes
curcnt  byte 0
; ---- explosions and power-ups (see stage 9) ----------------
exrows  byte 0,0,0,0
excols  byte 0,0,0,0
extim   byte 0,0,0,0          ; 0 = slot free
extmp   byte 0
extmp2  byte 0
pwactive byte 0
pwtype  byte 0                ; 0 grenade, 1 shovel, 2 watch
pwrow   byte 0
pwcol   byte 0
pwtmp   byte 0
pwlife  byte 0
pwphase byte 0
pwtick  byte 0                ; /8 prescaler for the two timers
fieldcap byte 4
p1kills byte 0,0              ; per-player kills this stage
killer  byte 0
mobonus byte 0,0,0,0
moanim  byte 0,0,0,0
mostep  byte 0,0,0,0          ; this tank carries a power-up and flashes
pwtaker byte 0
pwx     byte 0                ; a candidate item's position, in pixels
pwy     byte 0                ; 0 = player 1 collected it, 1 = player 2
p1shield byte 0
p2shield byte 0
p1star  byte 0
p2star  byte 0
p1cool  byte 0
p2cool  byte 0
p1respawn byte 0
p2respawn byte 0
bstar   byte 0                ; gun level of whoever fired the live bullet
pwglyph byte pwdrone,pwshov,pwwatch,pwtank,pwhelm,pwstar
pbactive byte 0,0,0,0         ; slots 0-1 player 1, slots 2-3 player 2
pbx     byte 0,0,0,0
pby     byte 0,0,0,0
pbdir   byte 0,0,0,0
pbidx   byte 0
fireown byte 0
fireslot byte 0
fireallow byte 0
firecount byte 0
firefree byte 0
firedir byte 0
firex   byte 0
firey   byte 0
muxslot byte 0
muxbit  byte 0
muxtmp  byte 0                ; which of sprites 2-7 is next
freezetimer byte 0
shieldtimer byte 0
g2row   byte 0
g2col   byte 0
gbase   byte 0
gcol    byte 0
pchar   byte 0
pcol    byte 0
cc2r    byte 0
cc2c    byte 0
nestval byte 0
nestval2 byte 0
nesttop byte 0
basetop byte 23
nestr   byte 0
nestc   byte 0
sfval   byte 0
gtmp    byte 0
ktmp    byte 0
pibx    byte 0
piby    byte 0
seed    byte 1

; ---- level data: 26x25, 0=floor 1=brick 2=steel 3=base -----
; ---- 4=p1 spawn 5=p2 spawn 6=enemy spawn -------------------
; ---- exported from the level editor; paste a new export ----
; ---- here to try a different layout. the base cells (rows ---
; ---- 21-22, cols 12-13) are fixed by convention - the editor
; ---- won't let you move them, matching the original game.
; ---- tanks are 16x16 (2 tile cells): a spawn point needs a
; ---- full 2x2 clearance of non-solid cells around it, or the
; ---- tank starts overlapping a wall. row 22 (not 23) is the
; ---- lowest safe player-spawn row here, since row 24 is the
; ---- bottom border and a spawn at row 23 would already
; ---- overlap it.

; ---- writable copy of level1: 26x25, mutated at runtime once
; ---- bricks start getting destroyed (a later stage). always
; ---- holds only {0 floor, 1 brick, 2 steel, 3 base} - see
; ---- normfield. reserved here as zeros; readlevel fills it.

; ---- sprite data: tank, 4 directional frames, 24x21 hires --
; ---- pointer = 192 + facing (0=up 1=down 2=left 3=right),  -
; ---- so selecting a frame is just "192 + facing", no lookup -
; ---- table needed. hull + turret + barrel, tapering toward -
; ---- the direction the tank is facing.
*=$5000
tank_up0
        byte %00000001,%10000000,%00000000
        byte %00000001,%10000000,%00000000
        byte %00000001,%10000000,%00000000
        byte %00000001,%10000000,%00000000
        byte %10100111,%11100101,%00000000
        byte %11101111,%11110111,%00000000
        byte %10101100,%00110101,%00000000
        byte %11101011,%11010111,%00000000
        byte %10101011,%11010101,%00000000
        byte %11101100,%00110111,%00000000
        byte %10101111,%11110101,%00000000
        byte %11101111,%11110111,%00000000
        byte %10101111,%11110101,%00000000
        byte %11100111,%11100111,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000

*=$5040
tank_up1
        byte %00000001,%10000000,%00000000
        byte %00000001,%10000000,%00000000
        byte %00000001,%10000000,%00000000
        byte %00000001,%10000000,%00000000
        byte %11100111,%11100111,%00000000
        byte %10101111,%11110101,%00000000
        byte %11101100,%00110111,%00000000
        byte %10101011,%11010101,%00000000
        byte %11101011,%11010111,%00000000
        byte %10101100,%00110101,%00000000
        byte %11101111,%11110111,%00000000
        byte %10101111,%11110101,%00000000
        byte %11101111,%11110111,%00000000
        byte %10100111,%11100101,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000

*=$5080
tank_down0
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %11100111,%11100111,%00000000
        byte %10101111,%11110101,%00000000
        byte %11101111,%11110111,%00000000
        byte %10101111,%11110101,%00000000
        byte %11101100,%00110111,%00000000
        byte %10101011,%11010101,%00000000
        byte %11101011,%11010111,%00000000
        byte %10101100,%00110101,%00000000
        byte %11101111,%11110111,%00000000
        byte %10100111,%11100101,%00000000
        byte %00000001,%10000000,%00000000
        byte %00000001,%10000000,%00000000
        byte %00000001,%10000000,%00000000
        byte %00000001,%10000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000

*=$50c0
tank_down1
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %10100111,%11100101,%00000000
        byte %11101111,%11110111,%00000000
        byte %10101111,%11110101,%00000000
        byte %11101111,%11110111,%00000000
        byte %10101100,%00110101,%00000000
        byte %11101011,%11010111,%00000000
        byte %10101011,%11010101,%00000000
        byte %11101100,%00110111,%00000000
        byte %10101111,%11110101,%00000000
        byte %11100111,%11100111,%00000000
        byte %00000001,%10000000,%00000000
        byte %00000001,%10000000,%00000000
        byte %00000001,%10000000,%00000000
        byte %00000001,%10000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000

*=$5100
tank_left0
        byte %00001111,%11111100,%00000000
        byte %00000101,%01010100,%00000000
        byte %00001111,%11111100,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000111,%11111000,%00000000
        byte %00001110,%01111100,%00000000
        byte %00001101,%10111100,%00000000
        byte %11111101,%10111100,%00000000
        byte %11111101,%10111100,%00000000
        byte %00001101,%10111100,%00000000
        byte %00001110,%01111100,%00000000
        byte %00000111,%11111000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00001111,%11111100,%00000000
        byte %00000101,%01010100,%00000000
        byte %00001111,%11111100,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000

*=$5140
tank_left1
        byte %00001111,%11111100,%00000000
        byte %00001010,%10101000,%00000000
        byte %00001111,%11111100,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000111,%11111000,%00000000
        byte %00001110,%01111100,%00000000
        byte %00001101,%10111100,%00000000
        byte %11111101,%10111100,%00000000
        byte %11111101,%10111100,%00000000
        byte %00001101,%10111100,%00000000
        byte %00001110,%01111100,%00000000
        byte %00000111,%11111000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00001111,%11111100,%00000000
        byte %00001010,%10101000,%00000000
        byte %00001111,%11111100,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000

*=$5180
tank_right0
        byte %00111111,%11110000,%00000000
        byte %00101010,%10100000,%00000000
        byte %00111111,%11110000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00011111,%11100000,%00000000
        byte %00111110,%01110000,%00000000
        byte %00111101,%10110000,%00000000
        byte %00111101,%10111111,%00000000
        byte %00111101,%10111111,%00000000
        byte %00111101,%10110000,%00000000
        byte %00111110,%01110000,%00000000
        byte %00011111,%11100000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00111111,%11110000,%00000000
        byte %00101010,%10100000,%00000000
        byte %00111111,%11110000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000

*=$51c0
tank_right1
        byte %00111111,%11110000,%00000000
        byte %00010101,%01010000,%00000000
        byte %00111111,%11110000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00011111,%11100000,%00000000
        byte %00111110,%01110000,%00000000
        byte %00111101,%10110000,%00000000
        byte %00111101,%10111111,%00000000
        byte %00111101,%10111111,%00000000
        byte %00111101,%10110000,%00000000
        byte %00111110,%01110000,%00000000
        byte %00011111,%11100000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00111111,%11110000,%00000000
        byte %00010101,%01010000,%00000000
        byte %00111111,%11110000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000

*=$5200
bulletspr
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00111100,%00000000,%00000000
        byte %00111100,%00000000,%00000000
        byte %00111100,%00000000,%00000000
        byte %00111100,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000
        byte %00000000,%00000000,%00000000

*=$5240
; ------------------------------------------------------------
; leveldata   35 stages, each a 13 x 11 grid of 2x2 blocks packed
;             two blocks to a byte. 143 blocks = 72 bytes a stage,
;             2520 for the set. it lives up here in the spare RAM of
;             the vic bank rather than below $4000: the vic only
;             fetches the screen, charset and sprite areas, so the
;             rest of its 16k is ordinary memory. keeping it out of
;             the code area is what lets the code stay under $4000,
;             which is what lets the graphics sit at $4400 instead of
;             $8400 - and that closed a 15k hole in the prg.
;
;             nibble codes: 0 floor, 1 brick, 2 armour, 3 river,
;             4 forest, 5 ice. the high nibble of each byte is the
;             earlier block.
;
;             the base, its nest, the player spawns and the three
;             entry points are NOT in here - they are the same on
;             every stage and readlevel stamps them.
; ------------------------------------------------------------
leveldata
; --- stage 1
        byte $00,$10,$10,$00,$10,$10,$00,$01,$01,$02,$01,$01
        byte $00,$00,$10,$10,$00,$10,$10,$00,$01,$01,$01,$01
        byte $01,$00,$00,$00,$00,$00,$00,$00,$02,$01,$01,$00
        byte $01,$01,$02,$00,$10,$10,$00,$10,$10,$00,$00,$00
        byte $00,$00,$00,$00,$00,$10,$10,$00,$10,$10,$00,$01
        byte $00,$00,$00,$01,$00,$00,$00,$00,$00,$00,$00,$00
; --- stage 2
        byte $00,$10,$00,$00,$10,$10,$00,$01,$01,$00,$01,$01
        byte $00,$00,$10,$00,$20,$10,$10,$00,$01,$01,$11,$00
        byte $01,$00,$02,$00,$10,$00,$10,$10,$24,$40,$01,$04
        byte $01,$00,$44,$44,$01,$00,$04,$00,$04,$40,$01,$01
        byte $00,$01,$01,$00,$00,$10,$00,$10,$10,$00,$00,$01
        byte $00,$00,$00,$01,$00,$00,$00,$00,$00,$00,$00,$00
; --- stage 3
        byte $04,$44,$00,$00,$01,$20,$04,$44,$40,$10,$00,$12
        byte $01,$44,$44,$00,$01,$01,$20,$04,$44,$40,$10,$00
        byte $12,$01,$00,$10,$00,$10,$00,$10,$01,$10,$00,$22
        byte $20,$00,$10,$00,$00,$10,$00,$10,$01,$00,$21,$10
        byte $00,$00,$44,$44,$12,$11,$00,$01,$04,$44,$40,$21
        byte $00,$00,$00,$44,$44,$00,$00,$00,$00,$00,$00,$00
; --- stage 4   ; the commodore logo in steel: the C, and the = clear of it
        byte $00,$00,$00,$00,$00,$00,$04,$44,$00,$00,$00,$04
        byte $44,$42,$40,$22,$22,$20,$42,$44,$44,$22,$00,$00
        byte $04,$44,$30,$02,$20,$02,$22,$20,$33,$00,$22,$00
        byte $00,$00,$03,$00,$02,$20,$02,$22,$20,$04,$44,$22
        byte $00,$00,$04,$44,$42,$40,$22,$22,$20,$42,$44,$44
        byte $00,$00,$00,$04,$44,$00,$00,$00,$00,$00,$00,$00
; --- stage 5
        byte $00,$01,$00,$00,$01,$00,$00,$20,$10,$00,$00,$10
        byte $00,$10,$01,$00,$10,$02,$00,$11,$00,$10,$01,$00
        byte $10,$01,$30,$33,$00,$20,$00,$00,$00,$00,$33,$03
        byte $30,$00,$00,$10,$01,$00,$03,$33,$03,$31,$00,$12
        byte $01,$00,$10,$01,$00,$00,$10,$00,$10,$00,$00,$10
        byte $11,$00,$01,$10,$10,$00,$00,$00,$00,$00,$00,$00
; --- stage 6
        byte $00,$10,$10,$00,$10,$10,$00,$01,$01,$00,$00,$14
        byte $10,$00,$10,$10,$20,$01,$41,$00,$01,$01,$00,$00
        byte $14,$10,$00,$00,$04,$44,$00,$00,$02,$20,$00,$44
        byte $40,$00,$22,$00,$00,$04,$44,$00,$00,$00,$01,$01
        byte $00,$00,$14,$10,$00,$10,$10,$20,$01,$41,$00,$01
        byte $00,$00,$00,$14,$10,$00,$00,$00,$00,$00,$00,$00
; --- stage 7
        byte $00,$02,$00,$00,$02,$00,$00,$22,$04,$00,$04,$02
        byte $20,$02,$04,$00,$20,$04,$02,$00,$24,$00,$02,$20
        byte $04,$20,$04,$00,$20,$22,$20,$04,$00,$00,$22,$00
        byte $02,$20,$00,$00,$40,$22,$20,$20,$40,$00,$20,$40
        byte $22,$00,$40,$20,$02,$00,$40,$20,$40,$02,$00,$20
        byte $20,$00,$00,$20,$20,$00,$00,$00,$00,$00,$00,$00
; --- stage 8
        byte $00,$10,$00,$00,$10,$10,$01,$01,$00,$10,$00,$01
        byte $01,$40,$00,$01,$00,$10,$00,$03,$30,$33,$33,$33
        byte $33,$03,$11,$00,$04,$44,$02,$00,$10,$00,$20,$44
        byte $41,$02,$00,$00,$10,$04,$44,$01,$00,$03,$33,$30
        byte $33,$33,$30,$33,$40,$01,$00,$00,$10,$00,$04,$01
        byte $00,$00,$00,$01,$01,$00,$00,$00,$00,$00,$00,$00
; --- stage 9    ; the seven-circles mahjong tile: steel pips in a forest face
        byte $00,$01,$00,$00,$01,$00,$01,$02,$24,$44,$44,$44
        byte $00,$00,$22,$42,$24,$44,$40,$11,$04,$44,$22,$44
        byte $22,$00,$00,$44,$44,$44,$42,$20,$11,$04,$44,$44
        byte $44,$44,$00,$00,$22,$44,$44,$42,$20,$11,$02,$24
        byte $44,$44,$22,$00,$00,$44,$44,$44,$44,$40,$11,$02
        byte $24,$00,$04,$22,$00,$10,$22,$00,$00,$02,$20,$10
; --- stage 10   ; a brick mass inside an edge lane: forest, steel, a short river
        byte $00,$01,$00,$00,$01,$00,$00,$11,$11,$11,$11,$11
        byte $10,$01,$12,$11,$11,$12,$11,$11,$11,$11,$12,$11
        byte $11,$10,$01,$11,$13,$33,$11,$11,$00,$11,$11,$11
        byte $11,$11,$10,$01,$21,$11,$21,$11,$21,$11,$11,$11
        byte $11,$11,$11,$10,$01,$14,$44,$44,$44,$11,$00,$11
        byte $10,$00,$00,$11,$10,$00,$00,$00,$00,$00,$00,$00
; --- stage 11   ; a four-thick forest band, bottom left to top right, in brick channels
        byte $00,$00,$00,$00,$00,$40,$41,$00,$02,$01,$01,$44
        byte $44,$10,$10,$10,$10,$44,$44,$20,$02,$01,$01,$44
        byte $44,$01,$10,$10,$14,$44,$44,$10,$11,$01,$04,$44
        byte $44,$02,$01,$10,$14,$44,$44,$10,$10,$11,$04,$44
        byte $44,$01,$01,$00,$44,$44,$40,$20,$10,$10,$14,$44
        byte $40,$00,$00,$02,$01,$44,$40,$00,$00,$00,$00,$00
; --- stage 12   ; a river across with three bridges and deltas up and down
        byte $00,$01,$00,$00,$01,$00,$00,$01,$00,$01,$00,$01
        byte $00,$10,$10,$00,$10,$00,$10,$00,$00,$03,$00,$03
        byte $00,$01,$00,$00,$32,$02,$30,$00,$03,$30,$33,$30
        byte $33,$30,$33,$03,$02,$00,$00,$02,$03,$00,$30,$10
        byte $00,$00,$10,$30,$00,$01,$00,$20,$01,$00,$01,$01
        byte $00,$00,$00,$01,$01,$00,$10,$00,$00,$00,$10,$00
; --- stage 13   ; a forest in the middle, brick channels and scattered steel round it
        byte $00,$00,$00,$00,$00,$00,$01,$00,$01,$01,$01,$00
        byte $01,$10,$14,$44,$44,$44,$10,$10,$02,$44,$44,$44
        byte $41,$02,$10,$14,$44,$44,$44,$20,$12,$01,$44,$44
        byte $44,$42,$01,$10,$10,$10,$10,$10,$10,$11,$01,$00
        byte $22,$21,$01,$00,$10,$10,$00,$00,$00,$20,$11,$00
        byte $00,$00,$00,$00,$01,$00,$00,$00,$00,$00,$00,$00
; --- stage 14   ; a brick skull with forest eyes, a river under the jaw, forest edges
        byte $04,$44,$44,$04,$44,$40,$44,$00,$11,$11,$11,$10
        byte $04,$40,$11,$11,$11,$11,$10,$44,$01,$44,$11,$14
        byte $41,$04,$40,$14,$41,$11,$44,$10,$44,$01,$11,$10
        byte $11,$11,$04,$40,$01,$11,$11,$11,$00,$44,$00,$10
        byte $10,$10,$10,$04,$33,$03,$33,$03,$33,$03,$34,$00
        byte $00,$00,$00,$00,$04,$40,$00,$00,$00,$00,$00,$40
; --- stage 15   ; a winding forest trail from player 1's start to the left channels
        byte $00,$00,$00,$00,$00,$00,$01,$01,$04,$44,$00,$00
        byte $00,$10,$10,$40,$40,$44,$40,$00,$00,$04,$04,$04
        byte $04,$20,$14,$44,$40,$40,$40,$40,$01,$01,$00,$04
        byte $44,$04,$01,$00,$00,$00,$20,$00,$40,$01,$02,$00
        byte $00,$00,$04,$00,$10,$10,$44,$44,$44,$40,$00,$00
        byte $04,$00,$00,$00,$01,$00,$00,$00,$00,$00,$00,$00
; --- stage 16   ; a praying mantis in forest, steel eyes, lying diagonally
        byte $00,$00,$00,$00,$00,$00,$00,$04,$24,$00,$00,$00
        byte $00,$04,$40,$04,$00,$00,$00,$00,$20,$40,$40,$00
        byte $00,$00,$04,$00,$40,$00,$44,$00,$00,$04,$40,$40
        byte $40,$04,$00,$00,$00,$04,$44,$04,$00,$02,$00,$04
        byte $04,$44,$00,$00,$02,$24,$00,$04,$44,$00,$00,$22
        byte $00,$00,$00,$44,$00,$00,$00,$00,$00,$00,$44,$00
; --- stage 17   ; the first ice: four patches, scattered brick, two steel
        byte $00,$00,$00,$00,$00,$00,$05,$55,$50,$10,$00,$55
        byte $55,$55,$55,$00,$21,$05,$55,$55,$55,$50,$01,$00
        byte $55,$55,$01,$05,$55,$55,$11,$00,$00,$11,$00,$55
        byte $50,$00,$00,$00,$10,$05,$55,$01,$00,$01,$00,$10
        byte $02,$01,$00,$01,$55,$55,$00,$00,$01,$00,$05,$55
        byte $50,$00,$00,$10,$00,$55,$55,$00,$00,$00,$00,$00
; --- stage 18   ; a chain of linked squares, steel and brick, bottom left to top right
        byte $00,$00,$00,$00,$22,$20,$00,$00,$00,$00,$04,$02
        byte $00,$01,$10,$00,$11,$24,$20,$00,$11,$00,$01,$01
        byte $00,$00,$00,$00,$24,$11,$10,$00,$00,$00,$02,$02
        byte $00,$00,$00,$00,$11,$24,$20,$00,$00,$00,$01,$01
        byte $00,$00,$21,$21,$22,$11,$40,$00,$00,$00,$02,$04
        byte $00,$00,$00,$01,$21,$24,$20,$00,$00,$00,$00,$00
; --- stage 19   ; brick bars, a forest band a third up, steel over the reactor's lane
        byte $01,$01,$01,$01,$01,$00,$00,$00,$00,$00,$00,$00
        byte $00,$01,$01,$01,$01,$01,$01,$00,$10,$10,$12,$10
        byte $10,$10,$11,$01,$01,$01,$01,$01,$10,$10,$10,$10
        byte $10,$10,$10,$44,$44,$44,$44,$44,$44,$44,$44,$44
        byte $44,$44,$44,$44,$01,$01,$01,$01,$01,$01,$00,$10
        byte $10,$00,$00,$10,$10,$01,$01,$00,$00,$01,$01,$00
; --- stage 20   ; a river up, left, and up again, three crossings; two forests
        byte $00,$03,$01,$00,$00,$00,$01,$00,$31,$10,$01,$00
        byte $10,$10,$00,$00,$02,$10,$00,$00,$01,$30,$44,$44
        byte $00,$00,$01,$13,$24,$44,$40,$00,$00,$00,$30,$01
        byte $00,$00,$01,$00,$13,$33,$30,$33,$30,$00,$00,$00
        byte $20,$00,$03,$01,$10,$20,$00,$11,$00,$04,$40,$00
        byte $10,$00,$00,$13,$44,$00,$01,$00,$00,$01,$34,$40
; --- stage 21   ; a circle of brick with a peace symbol carved in forest; steel shuts the way round
        byte $00,$01,$44,$44,$41,$00,$00,$01,$41,$14,$11,$41
        byte $00,$01,$41,$11,$41,$11,$41,$00,$14,$11,$14,$11
        byte $14,$10,$21,$41,$14,$44,$11,$41,$20,$14,$14,$14
        byte $14,$14,$10,$01,$44,$11,$41,$14,$41,$00,$01,$41
        byte $14,$11,$41,$00,$00,$01,$44,$44,$41,$00,$00,$00
        byte $01,$00,$01,$00,$00,$00,$00,$00,$00,$00,$00,$00
; --- stage 22   ; very open: brick and steel blocks, each wrapped in a cross of forest
        byte $00,$40,$00,$40,$00,$40,$00,$41,$40,$41,$40,$41
        byte $40,$00,$40,$00,$40,$00,$40,$04,$00,$04,$00,$04
        byte $00,$04,$24,$04,$14,$04,$14,$04,$24,$00,$04,$00
        byte $04,$00,$04,$00,$40,$00,$40,$00,$40,$00,$41,$40
        byte $42,$40,$41,$40,$00,$40,$00,$40,$00,$40,$00,$00
        byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
; --- stage 23   ; the radiation trefoil in steel, the reactor's way up, filling the map
        byte $00,$02,$00,$00,$02,$00,$00,$02,$20,$00,$00,$22
        byte $00,$02,$22,$20,$00,$22,$22,$00,$00,$22,$00,$02
        byte $20,$00,$00,$00,$00,$20,$00,$00,$04,$00,$00,$00
        byte $00,$00,$04,$24,$00,$00,$20,$00,$04,$24,$00,$00
        byte $22,$20,$00,$04,$00,$00,$22,$22,$20,$00,$00,$00
        byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
; --- stage 24   ; a massive ice patch over the centre and bottom right; forest top left
        byte $44,$44,$01,$01,$00,$01,$04,$44,$40,$10,$10,$10
        byte $10,$44,$44,$01,$00,$01,$01,$04,$44,$10,$12,$55
        byte $55,$12,$01,$01,$05,$55,$55,$55,$51,$10,$15,$55
        byte $55,$55,$55,$01,$00,$55,$55,$55,$55,$50,$10,$15
        byte $55,$55,$55,$55,$00,$01,$55,$55,$55,$55,$50,$10
        byte $15,$00,$05,$55,$55,$01,$01,$00,$00,$05,$55,$50
; --- stage 25   ; a maze: mostly brick, steel where tanks would drill through
        byte $00,$00,$00,$00,$00,$00,$01,$11,$11,$10,$20,$11
        byte $11,$00,$00,$00,$01,$00,$00,$00,$21,$21,$12,$12
        byte $21,$10,$00,$00,$00,$00,$00,$00,$00,$20,$10,$22
        byte $22,$11,$20,$01,$00,$02,$00,$00,$02,$00,$21,$22
        byte $12,$11,$10,$20,$00,$02,$00,$00,$01,$01,$00,$11
        byte $10,$00,$00,$11,$10,$00,$00,$00,$00,$00,$00,$00
; --- stage 26   ; a hash in brick, steel at its joints; river in the corners, forest edges
        byte $33,$44,$44,$44,$44,$43,$33,$30,$10,$00,$00,$10
        byte $33,$40,$01,$00,$00,$01,$00,$44,$11,$21,$11,$11
        byte $21,$14,$40,$01,$00,$00,$01,$00,$44,$00,$10,$00
        byte $00,$10,$04,$40,$01,$00,$00,$01,$00,$44,$11,$21
        byte $11,$11,$21,$14,$40,$01,$00,$00,$01,$00,$43,$30
        byte $10,$00,$00,$10,$33,$33,$44,$00,$00,$04,$43,$30
; --- stage 27   ; a maze of steel: brick doors and plugs to shoot through; forest about
        byte $02,$00,$00,$00,$00,$00,$00,$20,$22,$22,$22,$20
        byte $20,$02,$00,$02,$00,$00,$01,$04,$21,$20,$20,$21
        byte $21,$20,$01,$04,$02,$02,$04,$02,$00,$22,$22,$20
        byte $21,$20,$20,$04,$40,$01,$42,$02,$02,$42,$21,$20
        byte $20,$20,$21,$21,$02,$00,$00,$02,$00,$01,$00,$20
        byte $20,$00,$00,$20,$21,$41,$00,$00,$00,$02,$00,$00
; --- stage 28   ; a house: brick roof tiles lined with forest, ice up into the roof, chimney
        byte $00,$00,$00,$20,$00,$00,$20,$00,$00,$14,$10,$00
        byte $20,$00,$00,$24,$44,$20,$10,$00,$00,$14,$55,$54
        byte $11,$00,$00,$24,$55,$55,$54,$20,$00,$14,$55,$55
        byte $55,$54,$10,$24,$45,$55,$55,$55,$44,$24,$04,$55
        byte $55,$55,$54,$04,$00,$45,$55,$55,$55,$40,$00,$04
        byte $55,$00,$05,$54,$00,$00,$45,$00,$00,$05,$40,$00
; --- stage 29   ; six river pools linked by four forest patches; brick and steel about
        byte $01,$10,$20,$20,$21,$10,$00,$33,$44,$33,$44,$43
        byte $31,$13,$34,$43,$34,$44,$33,$02,$00,$00,$44,$00
        byte $00,$00,$00,$00,$13,$30,$10,$10,$11,$00,$01,$33
        byte $00,$00,$00,$04,$44,$44,$44,$44,$44,$00,$33,$10
        byte $00,$00,$03,$30,$13,$31,$00,$00,$00,$33,$00,$00
        byte $00,$00,$00,$00,$00,$02,$00,$00,$00,$00,$20,$00
; --- stage 30   ; a band of forest with wavy edges lined in brick; two river pools inside
        byte $01,$21,$00,$00,$01,$21,$01,$44,$41,$00,$01,$44
        byte $41,$44,$44,$41,$21,$44,$44,$44,$33,$44,$44,$44
        byte $43,$34,$43,$34,$44,$44,$44,$33,$44,$44,$44,$42
        byte $44,$44,$44,$44,$44,$44,$44,$44,$44,$44,$44,$11
        byte $44,$41,$14,$44,$44,$20,$01,$21,$00,$24,$41,$10
        byte $00,$00,$00,$00,$11,$00,$00,$00,$00,$00,$00,$00
; --- stage 31   ; a maze with walls of water: forest channels, brick shortcuts
        byte $00,$01,$03,$00,$00,$00,$03,$31,$30,$32,$30,$31
        byte $33,$44,$43,$00,$00,$01,$00,$00,$33,$30,$31,$30
        byte $30,$30,$01,$40,$00,$03,$00,$03,$00,$34,$33,$30
        byte $30,$30,$30,$00,$43,$44,$41,$03,$00,$03,$33,$30
        byte $31,$33,$30,$31,$00,$00,$00,$44,$40,$03,$00,$33
        byte $30,$00,$00,$33,$30,$00,$00,$00,$00,$00,$00,$00
; --- stage 32   ; mostly ice: a stag's head in brick, the reactor its nose; curved corner walls
        byte $51,$55,$15,$55,$15,$51,$55,$51,$01,$00,$01,$01
        byte $55,$55,$51,$10,$00,$11,$55,$55,$55,$51,$02,$01
        byte $55,$55,$55,$55,$11,$11,$15,$55,$55,$11,$10,$00
        byte $00,$11,$15,$55,$51,$01,$01,$01,$55,$51,$15,$51
        byte $00,$01,$55,$11,$55,$15,$01,$21,$05,$15,$50,$00
        byte $10,$00,$00,$10,$00,$00,$00,$00,$00,$00,$00,$00
; --- stage 33   ; a forest band with diagonal steel streams out of it; no brick at all
        byte $00,$20,$00,$02,$00,$42,$40,$00,$20,$00,$22,$44
        byte $44,$00,$00,$20,$00,$42,$44,$20,$00,$00,$20,$44
        byte $24,$00,$20,$00,$04,$44,$44,$20,$00,$20,$02,$44
        byte $44,$00,$20,$00,$24,$44,$44,$20,$00,$22,$02,$24
        byte $42,$00,$22,$00,$44,$44,$40,$00,$00,$20,$04,$44
        byte $40,$00,$00,$00,$20,$44,$40,$00,$00,$02,$00,$20
; --- stage 34   ; all brick: a demon with a pitchfork, filling the screen
        byte $00,$00,$10,$00,$10,$10,$10,$00,$01,$11,$11,$01
        byte $11,$00,$00,$10,$10,$10,$01,$00,$00,$01,$11,$11
        byte $00,$10,$00,$00,$01,$11,$00,$01,$01,$11,$11,$11
        byte $11,$11,$11,$10,$01,$11,$11,$11,$01,$00,$00,$11
        byte $11,$11,$10,$10,$00,$01,$10,$00,$11,$01,$00,$00
        byte $10,$00,$00,$10,$10,$00,$11,$00,$00,$01,$11,$00
; --- stage 35   ; a pool across the map between banks of trees; a smiling brick fish
        byte $00,$00,$00,$00,$00,$00,$04,$44,$44,$44,$44,$44
        byte $44,$44,$44,$44,$24,$44,$44,$41,$13,$31,$11,$11
        byte $11,$33,$31,$13,$11,$21,$21,$11,$33,$31,$11,$41
        byte $11,$41,$11,$31,$13,$11,$44,$41,$11,$31,$13,$31
        byte $11,$11,$11,$33,$44,$44,$44,$44,$44,$44,$40,$00
        byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
; --- wave 99   ; the last battlefield, a map of its own: THE END in steel.
;                the E's middle bars use the half blocks (6 and 7)
        byte $02,$22,$02,$02,$02,$22,$00,$02,$00,$22,$20,$27
        byte $00,$00,$20,$02,$02,$02,$60,$00,$02,$00,$20,$20
        byte $22,$20,$10,$00,$00,$00,$00,$00,$10,$22,$20,$22
        byte $00,$22,$00,$02,$70,$02,$02,$02,$02,$00,$26,$00
        byte $20,$20,$20,$20,$02,$22,$02,$02,$02,$20,$00,$00
        byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00

; ------------------------------------------------------------
; stagemix   the twenty arrivals of each stage, by type:
;            light, armoured car, rapid-fire, heavy. four bytes
;            a stage, always summing to twenty.
;
;            each type gets its own debut and then grows while the
;            ones before it thin out: armoured cars at stage 3,
;            rapid-fire at 8, heavies at 14.
;
;            the numbers always run opposite to the danger - light
;            tanks are the most common, heavies the fewest, and no
;            type ever outnumbers a weaker one. that caps the hardest
;            possible stage at a flat 5/5/5/5, which is reached
;            around stage 30. difficulty past that comes from the
;            loop promotion, not from the counts.
;
;            past stage 35 the maps repeat, and every tank in the
;            formation is promoted one grade per loop - so the
;            same formation that was mostly light tanks first
;            time round arrives as armoured cars, then rapid-fire,
;            then heavies. that is what makes the loops harder
;            without needing 35 more formations.
; ------------------------------------------------------------
stagemix
        byte 20, 0, 0, 0     ; stage 1
        byte 20, 0, 0, 0     ; stage 2
        byte 17, 3, 0, 0     ; stage 3
        byte 17, 3, 0, 0     ; stage 4
        byte 16, 4, 0, 0     ; stage 5
        byte 15, 5, 0, 0     ; stage 6
        byte 15, 5, 0, 0     ; stage 7
        byte 14, 5, 1, 0     ; stage 8
        byte 13, 5, 2, 0     ; stage 9
        byte 12, 6, 2, 0     ; stage 10
        byte 11, 6, 3, 0     ; stage 11
        byte 11, 6, 3, 0     ; stage 12
        byte 10, 6, 4, 0     ; stage 13
        byte 10, 6, 3, 1     ; stage 14
        byte  9, 6, 4, 1     ; stage 15
        byte  8, 6, 4, 2     ; stage 16
        byte  8, 6, 4, 2     ; stage 17
        byte  8, 6, 4, 2     ; stage 18
        byte  7, 6, 4, 3     ; stage 19
        byte  7, 6, 4, 3     ; stage 20
        byte  7, 6, 4, 3     ; stage 21
        byte  6, 6, 5, 3     ; stage 22
        byte  6, 6, 5, 3     ; stage 23
        byte  6, 6, 5, 3     ; stage 24
        byte  6, 5, 5, 4     ; stage 25
        byte  6, 5, 5, 4     ; stage 26
        byte  6, 5, 5, 4     ; stage 27
        byte  5, 5, 5, 5     ; stage 28
        byte  5, 5, 5, 5     ; stage 29
        byte  5, 5, 5, 5     ; stage 30
        byte  5, 5, 5, 5     ; stage 31
        byte  5, 5, 5, 5     ; stage 32
        byte  5, 5, 5, 5     ; stage 33
        byte  5, 5, 5, 5     ; stage 34
        byte  5, 5, 5, 5     ; stage 35

; ------------------------------------------------------------
; duelmap   the versus map. a DIFFERENT grid from the stages:
;           12 block rows with the spare row in the MIDDLE (12)
;           rather than three at the top. that is the only
;           layout in which block rows mirror onto each other -
;           with the spare rows at the top, block row 0 covers
;           cells 3-4 and reflects to 20-21, which is not a block
;           boundary, so a symmetric duel map is impossible.
;
;           built by reflecting one quarter twice, so it is exact
;           top/bottom and left/right. 78 bytes.
; ------------------------------------------------------------
duelmap
        byte $00,$00,$00,$00,$00,$00,$00,$01,$01,$00,$01,$01,$00
        byte $00,$10,$10,$00,$10,$10,$02,$00,$00,$00,$00,$00,$02
        byte $00,$44,$00,$00,$04,$40,$00,$01,$00,$02,$00,$01,$00
        byte $00,$10,$00,$20,$00,$10,$00,$04,$40,$00,$00,$44,$00
        byte $20,$00,$00,$00,$00,$00,$20,$01,$01,$00,$01,$01,$00
        byte $00,$10,$10,$00,$10,$10,$00,$00,$00,$00,$00,$00,$00

*=$5d40
; ------------------------------------------------------------
; the missile, nose down - it is falling onto the reactor
; ------------------------------------------------------------
icbmspr
        byte $01,$81,$80
        byte $01,$c3,$80
        byte $00,$ff,$00
        byte $00,$7e,$00
        byte $00,$3c,$00
        byte $00,$3c,$00
        byte $00,$3c,$00
        byte $00,$3c,$00
        byte $00,$3c,$00
        byte $00,$3c,$00
        byte $00,$3c,$00
        byte $00,$3c,$00
        byte $00,$3c,$00
        byte $00,$3c,$00
        byte $00,$3c,$00
        byte $00,$3c,$00
        byte $00,$3c,$00
        byte $00,$3c,$00
        byte $00,$18,$00
        byte $00,$18,$00
        byte $00,$18,$00
        byte 0

*=$5d80
; ------------------------------------------------------------
; the custom character shapes. read once, when initchars builds the
; character set, so they need not sit in the main block - and they
; must not: at 488 bytes they were the difference between the code
; fitting below the screen at $4400 and spilling into it.
; ------------------------------------------------------------
customglyphs
        ; 96 brick
        byte %11101110
        byte %11101110
        byte %11101110
        byte %00000000
        byte %10111011
        byte %10111011
        byte %10111011
        byte %00000000
        ; 97 steel
        byte %01111110
        byte %11111111
        byte %11111111
        byte %11100111
        byte %11100111
        byte %11111111
        byte %11111111
        byte %01111110
        ; 98-101 eagle
        byte %00000000
        byte %00000000
        byte %00010000
        byte %00111000
        byte %01111100
        byte %01111000
        byte %01110001
        byte %11110011
        byte %00000000
        byte %00000000
        byte %00001000
        byte %00011100
        byte %00111110
        byte %00011110
        byte %10001110
        byte %11001111
        byte %00000011
        byte %00000001
        byte %00000000
        byte %00000011
        byte %00000011
        byte %00000111
        byte %00000111
        byte %00000001
        byte %11000000
        byte %10000000
        byte %00000000
        byte %11000000
        byte %11000000
        byte %11100000
        byte %11100000
        byte %10000000
        ; 102-105 explosion frame 1
        byte %00000000
        byte %00000001
        byte %00000001
        byte %00011001
        byte %00011101
        byte %00001111
        byte %00000111
        byte %01111111
        byte %00000000
        byte %10000000
        byte %10000000
        byte %10011000
        byte %10111000
        byte %11110000
        byte %11100000
        byte %11111110
        byte %01111111
        byte %00000111
        byte %00001111
        byte %00011101
        byte %00011001
        byte %00000001
        byte %00000001
        byte %00000000
        byte %11111110
        byte %11100000
        byte %11110000
        byte %10111000
        byte %10011000
        byte %10000000
        byte %10000000
        byte %00000000
        ; 106-109 explosion frame 2
        byte %00000000
        byte %00001110
        byte %00001111
        byte %00001111
        byte %01111110
        byte %01111000
        byte %01111000
        byte %00110000
        byte %00000000
        byte %01110000
        byte %11110000
        byte %11110000
        byte %01111110
        byte %00011110
        byte %00011110
        byte %00001100
        byte %00110000
        byte %01111000
        byte %01111000
        byte %01111110
        byte %00001111
        byte %00001111
        byte %00001110
        byte %00000000
        byte %00001100
        byte %00011110
        byte %00011110
        byte %01111110
        byte %11110000
        byte %11110000
        byte %01110000
        byte %00000000
        ; 110-113 drone strike
        byte %00001111
        byte %00110000
        byte %01100000
        byte %11000000
        byte %10011000
        byte %10111100
        byte %10001001
        byte %10000011
        byte %11110000
        byte %00001100
        byte %00000110
        byte %00000011
        byte %00011001
        byte %00111101
        byte %10010001
        byte %11000001
        byte %10000011
        byte %10001001
        byte %10111100
        byte %10011000
        byte %11000000
        byte %01100000
        byte %00110000
        byte %00001111
        byte %11000001
        byte %10010001
        byte %00111101
        byte %00011001
        byte %00000011
        byte %00000110
        byte %00001100
        byte %11110000
        ; 114-117 shovel
        byte %00001111
        byte %00110000
        byte %01100000
        byte %11000000
        byte %10000001
        byte %10000001
        byte %10000001
        byte %10000011
        byte %11110000
        byte %00001100
        byte %00000110
        byte %00000011
        byte %10000001
        byte %10000001
        byte %10000001
        byte %11000001
        byte %10000111
        byte %10000111
        byte %10000011
        byte %10000001
        byte %11000000
        byte %01100000
        byte %00110000
        byte %00001111
        byte %11100001
        byte %11100001
        byte %11000001
        byte %10000001
        byte %00000011
        byte %00000110
        byte %00001100
        byte %11110000
        ; 118-121 watch
        byte %00001111
        byte %00110000
        byte %01100000
        byte %11000000
        byte %10000011
        byte %10000100
        byte %10001001
        byte %10001001
        byte %11110000
        byte %00001100
        byte %00000110
        byte %00000011
        byte %11000001
        byte %00100001
        byte %10010001
        byte %10010001
        byte %10001001
        byte %10001000
        byte %10000100
        byte %10000011
        byte %11000000
        byte %01100000
        byte %00110000
        byte %00001111
        byte %11010001
        byte %00010001
        byte %00100001
        byte %11000001
        byte %00000011
        byte %00000110
        byte %00001100
        byte %11110000
        ; 122-125 extra tank
        byte %00001111
        byte %00110000
        byte %01100000
        byte %11000000
        byte %10000001
        byte %10000011
        byte %10001111
        byte %10001011
        byte %11110000
        byte %00001100
        byte %00000110
        byte %00000011
        byte %10000001
        byte %11000001
        byte %11110001
        byte %11010001
        byte %10001011
        byte %10001111
        byte %10000000
        byte %10000000
        byte %11000000
        byte %01100000
        byte %00110000
        byte %00001111
        byte %11010001
        byte %11110001
        byte %00000001
        byte %00000001
        byte %00000011
        byte %00000110
        byte %00001100
        byte %11110000
        ; 126-129 helmet
        byte %00001111
        byte %00110000
        byte %01100000
        byte %11000000
        byte %10000011
        byte %10000111
        byte %10001111
        byte %10001111
        byte %11110000
        byte %00001100
        byte %00000110
        byte %00000011
        byte %11000001
        byte %11100001
        byte %11110001
        byte %11110001
        byte %10001111
        byte %10000111
        byte %10001111
        byte %10000000
        byte %11000000
        byte %01100000
        byte %00110000
        byte %00001111
        byte %11110001
        byte %11100001
        byte %11110001
        byte %00000001
        byte %00000011
        byte %00000110
        byte %00001100
        byte %11110000
        ; 130-133 star
        byte %00001111
        byte %00110000
        byte %01100000
        byte %11000000
        byte %10000001
        byte %10000001
        byte %10000011
        byte %10001111
        byte %11110000
        byte %00001100
        byte %00000110
        byte %00000011
        byte %10000001
        byte %10000001
        byte %11000001
        byte %11110001
        byte %10000111
        byte %10000011
        byte %10000110
        byte %10001100
        byte %11000000
        byte %01100000
        byte %00110000
        byte %00001111
        byte %11100001
        byte %11000001
        byte %01100001
        byte %00110001
        byte %00000011
        byte %00000110
        byte %00001100
        byte %11110000
        ; 134 brick, top half remains
        byte %11101110
        byte %11101110
        byte %11101110
        byte %00000000
        byte %00000000
        byte %00000000
        byte %00000000
        byte %00000000
        ; 135 brick, bottom half remains
        byte %00000000
        byte %00000000
        byte %00000000
        byte %00000000
        byte %10111011
        byte %10111011
        byte %10111011
        byte %00000000
        ; 136 brick, left half remains
        byte %11100000
        byte %11100000
        byte %11100000
        byte %00000000
        byte %10110000
        byte %10110000
        byte %10110000
        byte %00000000
        ; 137 brick, right half remains
        byte %00001110
        byte %00001110
        byte %00001110
        byte %00000000
        byte %00001011
        byte %00001011
        byte %00001011
        byte %00000000
        ; 138 brick, top-left corner
        byte %11100000
        byte %11100000
        byte %11100000
        byte %00000000
        byte %00000000
        byte %00000000
        byte %00000000
        byte %00000000
        ; 139 brick, top-right corner
        byte %00001110
        byte %00001110
        byte %00001110
        byte %00000000
        byte %00000000
        byte %00000000
        byte %00000000
        byte %00000000
        ; 140 brick, bottom-left corner
        byte %00000000
        byte %00000000
        byte %00000000
        byte %00000000
        byte %10110000
        byte %10110000
        byte %10110000
        byte %00000000
        ; 141 brick, bottom-right corner
        byte %00000000
        byte %00000000
        byte %00000000
        byte %00000000
        byte %00001011
        byte %00001011
        byte %00001011
        byte %00000000
        ; 142 river
        byte %00110011
        byte %11111111
        byte %11001100
        byte %00000000
        byte %00110011
        byte %11111111
        byte %11001100
        byte %00000000
        ; 143 forest
        byte %01100110
        byte %11111111
        byte %11011011
        byte %10111101
        byte %01111110
        byte %11011011
        byte %11111111
        byte %01100110
        ; 144 ice
        byte %11001100
        byte %10000100
        byte %00110011
        byte %01100111
        byte %11001100
        byte %10000100
        byte %00110011
        byte %01100111
        ; 145 armour, top half
        byte %01111110
        byte %11111111
        byte %11111111
        byte %11100111
        byte %00000000
        byte %00000000
        byte %00000000
        byte %00000000
        ; 146 armour, bottom half
        byte %00000000
        byte %00000000
        byte %00000000
        byte %00000000
        byte %11100111
        byte %11111111
        byte %11111111
        byte %01111110
        ; 147 armour, left half
        byte %01110000
        byte %11110000
        byte %11110000
        byte %11100000
        byte %11100000
        byte %11110000
        byte %11110000
        byte %01110000
        ; 148 armour, right half
        byte %00001110
        byte %00001111
        byte %00001111
        byte %00000111
        byte %00000111
        byte %00001111
        byte %00001111
        byte %00001110
        ; 149 spawn marker, frame 1
        byte %00011000
        byte %00111100
        byte %11111101
        byte %01111110
        byte %00111100
        byte %01100110
        byte %10000001
        byte %00000000
        ; 150 spawn marker, frame 2
        byte %00011000
        byte %01011010
        byte %00111100
        byte %11111101
        byte %00111100
        byte %01011010
        byte %00011000
        byte %00000000
        ; 151-154 wrecked base
        byte %00011111
        byte %00111111
        byte %01111111
        byte %01111111
        byte %01111111
        byte %00011111
        byte %00011111
        byte %00000011
        byte %11111000
        byte %11111100
        byte %11111110
        byte %11111110
        byte %11111110
        byte %11111000
        byte %11111000
        byte %11000000
        byte %00000011
        byte %00000011
        byte %00000111
        byte %00000111
        byte %00011111
        byte %00111111
        byte %11111111
        byte %11111111
        byte %11000000
        byte %11000000
        byte %11100000
        byte %11100000
        byte %11111000
        byte %11111100
        byte %11111111
        byte %11111111
        ; 155 small tank, for the reserve count
        byte %00011000
        byte %01111110
        byte %11111111
        byte %10111101
        byte %10111101
        byte %11111111
        byte %00000000
        byte %00000000
        ; 156 star, one cell, for the sidebar pips
        byte %00011000
        byte %00111100
        byte %11111111
        byte %01111110
        byte %00111100
        byte %01100110
        byte %11000011
        byte %00000000

; ------------------------------------------------------------
; scrmsg   the scrolling message, ending in $ff. upper case only:
;          the character set has no lower case. twenty spaces at
;          the end, so it has cleared well away before it starts
;          again. curly quotes and the long dash are mapped to the
;          plain ones the character set has.
; ------------------------------------------------------------
scrmsg
        byte 19,8,1,12,12,32,23,5,32,16,12,1,25,32,1,32,7,1,13,5
        byte 63,32,32,32,23,5,12,3,15,13,5,32,20,15,32,34,14,15,2,15
        byte 4,25,32,23,9,14,19,34,32,45,32,20,8,5,32,1,9,32,19,12
        byte 15,16,32,20,8,5,25,32,3,15,21,12,4,14,39,20,32,19,20,15
        byte 16,46,32,8,5,18,5,39,19,32,20,8,5,32,15,2,12,9,7,1
        byte 20,15,18,25,32,19,3,18,15,12,12,25,32,13,5,19,19,1,7,5
        byte 46,32,20,8,5,32,19,3,5,14,1,18,9,15,58,32,19,15,13,5
        byte 32,13,1,4,32,15,12,4,32,4,9,3,20,1,20,15,18,45,6,15
        byte 18,45,12,9,6,5,32,6,5,5,12,19,32,20,8,1,20,32,8,5
        byte 32,8,1,19,14,39,20,32,12,5,6,20,32,1,32,19,21,6,6,9
        byte 3,9,5,14,20,12,25,32,2,9,7,32,5,14,15,21,7,8,32,4
        byte 5,14,20,32,9,14,32,8,9,19,20,15,18,25,32,2,5,6,15,18
        byte 5,32,8,5,32,5,22,5,14,20,21,1,12,12,25,32,16,15,16,19
        byte 32,8,9,19,32,3,12,15,7,19,46,32,8,5,32,19,5,14,4,19
        byte 32,1,12,12,32,8,9,19,32,18,21,19,20,5,4,32,15,12,4,32
        byte 20,1,14,11,19,32,20,15,32,1,32,14,5,9,7,8,2,15,18,9
        byte 14,7,32,3,15,21,14,20,18,25,32,9,14,32,15,18,4,5,18,32
        byte 20,15,32,3,12,1,9,13,32,1,32,3,8,5,1,16,32,22,9,3
        byte 20,15,18,25,32,6,15,18,32,8,9,13,19,5,12,6,32,1,14,4
        byte 32,2,15,15,19,20,32,20,8,5,32,12,15,3,1,12,32,23,1,18
        byte 32,5,3,15,14,15,13,25,32,23,8,9,12,5,32,19,5,14,4,9
        byte 14,7,32,1,12,12,32,20,8,5,32,25,15,21,14,7,32,13,5,14
        byte 32,15,6,6,32,20,15,32,23,1,18,32,20,15,32,4,9,5,44,32
        byte 5,14,19,21,18,9,14,7,32,14,15,2,15,4,25,32,3,1,14,32
        byte 3,8,1,12,12,5,14,7,5,32,8,9,19,32,18,21,12,5,32,1
        byte 20,32,8,15,13,5,46,32,13,5,1,14,23,8,9,12,5,32,20,8
        byte 5,32,14,5,9,7,8,2,15,18,9,14,7,32,3,15,21,14,20,18
        byte 25,32,3,1,12,12,19,32,6,15,18,32,8,5,12,16,32,20,15,32
        byte 20,8,5,32,9,14,20,5,18,14,1,20,9,15,14,1,12,32,3,15
        byte 13,13,21,14,9,20,25,46,32,20,8,5,32,9,14,20,5,18,14,1
        byte 20,9,15,14,1,12,32,1,18,13,19,32,4,5,1,12,5,18,19,32
        byte 1,14,4,32,2,1,14,11,5,18,19,32,18,21,14,14,9,14,7,32
        byte 20,8,5,32,23,15,18,12,4,32,19,13,5,12,12,32,1,32,2,21
        byte 19,9,14,5,19,19,32,15,16,16,15,18,20,21,14,9,20,25,32,9
        byte 14,32,1,18,13,19,32,19,1,12,5,19,32,1,14,4,32,18,5,3
        byte 15,14,19,20,18,21,3,20,9,15,14,32,3,15,14,20,18,1,3,20
        byte 19,44,32,19,15,32,20,8,5,25,32,19,5,14,4,32,25,15,21,32
        byte 1,32,3,15,21,16,12,5,32,15,6,32,4,5,3,5,14,20,32,20
        byte 1,14,11,19,32,19,15,32,20,8,5,25,32,4,15,14,39,20,32,8
        byte 1,22,5,32,20,15,32,7,5,20,32,20,8,5,9,18,32,8,1,14
        byte 4,19,32,4,9,18,20,25,46,32,14,15,23,32,9,20,39,19,32,21
        byte 16,32,20,15,32,25,15,21,32,20,15,32,6,5,14,4,32,15,6,6
        byte 32,20,8,5,32,9,14,22,1,4,5,18,19,32,9,14,32,1,14,32
        byte 1,20,20,18,9,20,9,15,14,1,12,32,23,1,18,46,32,21,14,6
        byte 15,18,20,21,14,1,20,5,12,25,32,20,8,5,32,5,14,5,13,25
        byte 32,1,18,5,32,19,15,32,3,12,21,13,19,25,32,1,14,4,32,19
        byte 20,21,16,9,4,32,20,8,1,20,32,20,8,5,25,39,18,5,32,12
        byte 9,11,5,12,25,32,20,15,32,19,8,5,12,12,32,25,15,21,18,32
        byte 14,21,3,12,5,1,18,32,16,15,23,5,18,16,12,1,14,20,19,32
        byte 23,9,20,8,15,21,20,32,18,5,1,12,9,19,9,14,7,32,20,8
        byte 5,32,3,15,14,19,5,17,21,5,14,3,5,19,46,46,46,46,46,32
        byte 34,20,8,5,32,23,1,18,32,9,19,32,14,15,20,32,13,5,1,14
        byte 20,32,20,15,32,2,5,32,23,15,14,44,32,9,20,32,9,19,32,13
        byte 5,1,14,20,32,20,15,32,2,5,32,3,15,14,20,9,14,21,15,21
        byte 19,46,34,32,32,32,45,32,1,6,20,5,18,32,7,5,15,18,7,5
        byte 32,15,18,23,5,12,12,44,32,34,49,57,56,52,34,32,32,32,34,23
        byte 1,18,32,9,19,32,1,32,18,1,3,11,5,20,46,32,9,20,32,1
        byte 12,23,1,25,19,32,8,1,19,32,2,5,5,14,46,32,9,20,32,9
        byte 19,32,16,15,19,19,9,2,12,25,32,20,8,5,32,15,12,4,5,19
        byte 20,44,32,5,1,19,9,12,25,32,20,8,5,32,13,15,19,20,32,16
        byte 18,15,6,9,20,1,2,12,5,44,32,19,21,18,5,12,25,32,20,8
        byte 5,32,13,15,19,20,32,22,9,3,9,15,21,19,46,32,9,20,32,9
        byte 19,32,20,8,5,32,15,14,12,25,32,15,14,5,32,9,14,20,5,18
        byte 14,1,20,9,15,14,1,12,32,9,14,32,19,3,15,16,5,46,32,9
        byte 20,32,9,19,32,20,8,5,32,15,14,12,25,32,15,14,5,32,9,14
        byte 32,23,8,9,3,8,32,20,8,5,32,16,18,15,6,9,20,19,32,1
        byte 18,5,32,18,5,3,11,15,14,5,4,32,9,14,32,4,15,12,12,1
        byte 18,19,32,1,14,4,32,20,8,5,32,12,15,19,19,5,19,32,9,14
        byte 32,12,9,22,5,19,46,34,32,32,32,45,32,18,5,20,46,32,13,1
        byte 10,46,32,7,5,14,46,32,19,13,5,4,12,5,25,32,2,21,20,12
        byte 5,18,44,32,34,23,1,18,32,9,19,32,1,32,18,1,3,11,5,20
        byte 34,32,32,32,20,8,5,32,7,1,13,5,32,23,1,19,32,23,18,9
        byte 20,20,5,14,32,2,25,32,1,14,20,8,18,15,16,9,3,39,19,32
        byte 3,12,1,21,4,5,32,1,9,44,32,13,21,19,9,3,32,2,25,32
        byte 19,21,14,15,32,1,14,4,32,20,3,8,1,9,11,15,22,19,11,25
        byte 46,32,4,9,18,5,3,20,9,14,7,44,32,1,9,32,10,15,3,11
        byte 5,25,9,14,7,44,32,1,14,4,32,13,5,1,20,32,16,18,15,24
        byte 25,9,14,7,32,2,25,32,14,1,20,8,1,14,32,2,21,20,3,8
        byte 5,18,32,9,14,32,50,48,50,54,46,32,7,18,5,5,20,9,14,7
        byte 19,32,20,15,32,5,22,5,18,25,15,14,5,32,23,8,15,32,8,1
        byte 20,5,19,32,1,9,46,32,9,32,12,15,22,5,32,25,15,21,32,1
        byte 12,12,46,46,46,46,32,32,32,7,9,22,5,32,16,5,1,3,5,32
        byte 1,32,3,8,1,14,3,5,46,32,32,32,32,32,32,32,32,32,32,32
        byte 32,32,32,32,32,32,32,32,32,32,32,32,32,$ff

; (no fixed address: this follows the scroller message, so the
; message can grow without running into it)
; ------------------------------------------------------------
; music: the state anthem on the title screen and the briefing, and
; the 1812 ditty under each wave banner. nothing else plays music.
;
; one player, two modes. each step is four bytes: voice 1, voice 2, a
; third byte, and a length in ticks (0 = the end). a note byte of 0 is
; a rest, 1-72 is c1-b6 and strikes the note, bit 7 HOLDS it on from
; the step before. in the anthem's mode the third byte is a chord that
; voice 3 arpeggiates, and the tune loops; in the ditty's it is a plain
; note for voice 3, and the tune plays once and stops.
;
; a note that differs from the last is struck straight on, no gap;
; only the same pitch struck again gets a short gap first.
; the tune pointer is self-modifying code, not zero page: the game
; draws with $fb. the notes come from the game's own table.
; ------------------------------------------------------------
anrelearly = 2
anarprate = 4
anthemrun
        lda anon              ; anything playing?
        beq @quiet
        jmp anplay            ; (too far for a branch)
@quiet  rts
anfetch
anfop   lda antune,y          ; the address here walks through the tune
        rts
anthemstop
        lda #0
        sta anon
        lda #$10              ; every voice's gate off
        sta $d404
        sta $d40b
        sta $d412
        rts
anthemstart
        lda #<antune
        ldx #>antune
        ldy #1                ; arpeggio on voice 3, and loop
        jmp anbegin
dittystart
        lda #<dittytune
        ldx #>dittytune
        ldy #0                ; three plain voices, once through
anbegin sta anfop+1
        sta anhome
        stx anfop+2
        stx anhome+1
        sty anmode
        ldx #$18
        lda #0
@clr    sta $d400,x
        dex
        bpl @clr
        lda #$0f
        sta $d418
        lda anmode
        beq @ditty
        lda #$28              ; the anthem: melody, attack 16ms decay 300ms
        sta $d405
        lda #$d6              ; sustain 13, release 204ms
        sta $d406
        lda #$28              ; bass
        sta $d40c
        lda #$e6
        sta $d40d
        lda #$00              ; arpeggio: straight in, well below the rest
        sta $d413
        lda #$60
        sta $d414
        jmp @go
@ditty  lda #$16              ; the ditty: crisper, for the fast notes.
        sta $d405             ; attack 8ms, decay 168ms
        lda #$a4              ; sustain 10, release 114ms
        sta $d406
        lda #$16              ; bass
        sta $d40c
        lda #$c4
        sta $d40d
        lda #$16              ; the inner voice, a little quieter
        sta $d413
        lda #$84
        sta $d414
@go     lda #0
        sta antimer
        sta anarpon
        sta ancur
        sta ancur+7
        sta ancur+14
        lda #1
        sta anon
        rts

anplay  lda anmode
        beq @noarp
        jsr anarp
@noarp  lda antimer
        beq annext
        dec antimer
        lda antimer
        cmp #anrelearly
        bne @out
        jsr anrelease
@out    rts

annext  ldy #3
        jsr anfetch
        bne @have
        lda anmode            ; the end: the anthem goes round again,
        bne @again            ; the ditty just stops
        jmp anthemstop
@again  lda anhome
        sta anfop+1
        lda anhome+1
        sta anfop+2
        jmp annext
@have   sta antimer
        ldy #0
        jsr anfetch
        ldx #0
        jsr anvoice
        ldy #1
        jsr anfetch
        ldx #7
        jsr anvoice
        ldy #2
        jsr anfetch
        ldx anmode
        bne @chord
        ldx #14               ; the ditty: voice 3 plays a line of its own
        jsr anvoice
        jmp @adv
@chord  jsr anchord
@adv    dec antimer
        lda anfop+1
        clc
        adc #4
        sta anfop+1
        bcc @done
        inc anfop+2
@done   rts

; a = note byte, x = the voice's register offset (0, 7 or 14)
anvoice cmp #0
        bne @sound
        lda #$10
        sta $d404,x
        rts
@sound  bmi @hold
        sta ancur,x           ; remember it, to spot a repeat
        tay
        lda notefreqlo-1,y
        sta $d400,x
        lda notefreqhi-1,y
        sta $d401,x
        lda #$10              ; gate off and straight on: a fresh attack,
        sta $d404,x           ; with no gap
        lda #$11
        sta $d404,x
@hold   rts

; two ticks before a step ends, a voice lets go only if its next note
; is the same pitch struck again, or a rest
anrelease
        ldy #0
        ldx #0
        jsr @one
        ldy #1
        ldx #7
        jsr @one
        lda anmode            ; voice 3 is the arpeggio in the anthem
        bne @done
        ldy #2
        ldx #14
        jsr @one
@done   rts
@one    jsr anfetch
        beq @off
        bmi @keep
        cmp ancur,x
        bne @keep
@off    lda #$10
        sta $d404,x
@keep   rts

; a = chord byte: 0 none; low bits the root note, bit 7 minor
anchord cmp #0
        bne @have
        lda #$10
        sta $d412
        lda #0
        sta anarpon
        rts
@have   sta anchordb
        lda anarpon
        bne @done
        lda #1
        sta anarpon
        lda #0
        sta anarpidx
        lda #anarprate
        sta anarpcnt
        jsr anarpnote
        lda #$10
        sta $d412
        lda #$11
        sta $d412
@done   rts

anarp   lda anarpon
        beq @done
        dec anarpcnt
        bne @done
        lda #anarprate
        sta anarpcnt
        inc anarpidx
        lda anarpidx
        cmp #3
        bcc @ok
        lda #0
        sta anarpidx
@ok     jsr anarpnote
@done   rts

anarpnote
        lda anchordb
        and #$7f
        sta anroot
        ldx anarpidx
        lda anchordb
        bmi @minor
        lda anmaj,x
        jmp @add
@minor  lda anmin,x
@add    clc
        adc anroot
        tay
        lda notefreqlo-1,y
        sta $d40e
        lda notefreqhi-1,y
        sta $d40f
        rts

anmaj   byte 0,4,7
anmin   byte 0,3,7
anon    byte 0
anmode  byte 0
anhome  byte 0,0
antimer byte 0
ancur   byte 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0   ; indexed by 0, 7 and 14
anchordb byte 0
anarpon byte 0
anarpidx byte 0
anarpcnt byte 0
anroot  byte 0

antune
        byte 0,0,28,59
        byte 47,0,28,40
        byte 175,16,28,20
        byte 47,144,28,20
        byte 44,144,28,100
        byte 45,144,28,20
        byte 47,144,28,20
        byte 47,144,28,20
        byte 45,144,28,20
        byte 44,144,28,20
        byte 42,23,35,20
        byte 44,20,160,19
        byte 47,23,35,40
        byte 52,25,153,60
        byte 180,23,28,20
        byte 180,21,33,39
        byte 51,21,33,20
        byte 49,149,33,20
        byte 47,23,35,41
        byte 45,23,35,20
        byte 173,21,33,20
        byte 44,16,28,39
        byte 47,15,35,40
        byte 49,13,153,40
        byte 52,141,153,40
        byte 180,21,33,39
        byte 51,20,160,20
        byte 49,18,158,20
        byte 47,16,28,20
        byte 175,20,28,20
        byte 52,148,28,20
        byte 180,21,33,20
        byte 180,21,33,40
        byte 52,149,33,20
        byte 54,149,33,20
        byte 56,23,28,80
        byte 54,23,35,39
        byte 182,23,35,20
        byte 52,21,33,20
        byte 180,16,28,100
        byte 52,144,28,19
        byte 59,23,35,20
        byte 59,151,35,20
        byte 59,16,28,20
        byte 59,144,28,21
        byte 56,144,28,40
        byte 184,16,28,20
        byte 52,144,28,19
        byte 44,144,28,20
        byte 45,16,33,20
        byte 47,16,28,40
        byte 45,144,28,20
        byte 47,16,28,20
        byte 54,23,35,20
        byte 59,151,35,19
        byte 59,23,35,40
        byte 52,25,153,60
        byte 180,23,28,20
        byte 52,21,33,40
        byte 57,149,33,20
        byte 61,149,33,20
        byte 59,23,35,40
        byte 57,23,35,40
        byte 56,16,28,39
        byte 47,15,35,20
        byte 47,143,35,20
        byte 49,13,153,40
        byte 52,141,153,20
        byte 180,23,28,20
        byte 180,21,33,39
        byte 51,149,33,20
        byte 49,149,33,20
        byte 47,20,160,40
        byte 52,148,160,21
        byte 180,20,28,20
        byte 180,21,33,20
        byte 52,149,33,19
        byte 57,21,33,20
        byte 57,21,33,20
        byte 56,23,28,40
        byte 59,151,28,20
        byte 56,151,28,20
        byte 54,23,35,20
        byte 45,151,35,19
        byte 173,18,158,20
        byte 173,23,35,20
        byte 52,16,28,80
        byte 52,16,28,39
        byte 44,15,160,21
        byte 47,143,160,20
        byte 52,21,33,20
        byte 180,25,153,40
        byte 180,25,153,20
        byte 180,25,153,20
        byte 56,153,153,19
        byte 54,153,153,20
        byte 52,153,153,20
        byte 51,20,160,40
        byte 47,148,160,20
        byte 175,16,28,20
        byte 175,20,28,39
        byte 45,148,28,20
        byte 47,148,28,20
        byte 49,21,33,61
        byte 47,21,33,20
        byte 49,21,33,20
        byte 52,149,33,19
        byte 51,149,33,20
        byte 49,149,33,20
        byte 47,16,28,40
        byte 44,144,28,20
        byte 172,20,28,20
        byte 172,16,28,39
        byte 42,144,28,20
        byte 47,144,28,20
        byte 45,18,158,60
        byte 173,21,33,20
        byte 49,18,158,39
        byte 54,146,158,41
        byte 52,21,33,20
        byte 56,25,153,20
        byte 52,153,153,40
        byte 180,23,28,39
        byte 52,151,28,20
        byte 56,151,28,20
        byte 57,21,33,60
        byte 54,149,33,20
        byte 52,18,158,39
        byte 54,146,158,40
        byte 182,23,35,81
        byte 59,151,35,39
        byte 187,23,35,40
        byte 59,16,28,40
        byte 63,16,28,20
        byte 56,144,28,20
        byte 184,16,28,39
        byte 59,144,28,20
        byte 57,16,33,20
        byte 59,16,28,40
        byte 57,144,28,20
        byte 52,16,28,20
        byte 54,23,35,20
        byte 59,151,35,19
        byte 59,23,35,41
        byte 52,25,153,60
        byte 180,23,28,20
        byte 52,21,33,20
        byte 45,149,33,19
        byte 52,149,33,20
        byte 52,149,33,20
        byte 47,18,35,20
        byte 42,23,35,20
        byte 45,18,158,20
        byte 173,23,35,20
        byte 47,16,28,20
        byte 44,144,28,19
        byte 47,15,35,40
        byte 49,13,153,40
        byte 52,141,153,20
        byte 49,23,35,21
        byte 52,21,33,20
        byte 45,149,33,39
        byte 173,21,33,20
        byte 47,20,160,40
        byte 52,148,160,20
        byte 52,20,28,20
        byte 180,21,33,20
        byte 45,149,33,19
        byte 52,21,33,20
        byte 57,21,33,20
        byte 56,23,28,60
        byte 56,151,28,20
        byte 59,23,35,20
        byte 54,151,35,19
        byte 54,151,35,20
        byte 52,151,36,21
        byte 47,16,36,20
        byte 52,144,36,20
        byte 180,16,36,40
        byte 180,12,36,20
        byte 48,140,36,39
        byte 48,140,36,20
        byte 176,17,29,20
        byte 48,145,29,20
        byte 45,17,29,20
        byte 53,145,29,20
        byte 57,17,29,20
        byte 60,145,29,19
        byte 57,145,29,20
        byte 58,145,29,20
        byte 60,17,29,40
        byte 58,145,29,20
        byte 53,145,29,21
        byte 55,12,36,20
        byte 48,140,36,19
        byte 48,140,36,20
        byte 48,140,36,20
        byte 53,14,154,20
        byte 53,142,154,20
        byte 57,142,154,20
        byte 53,12,29,20
        byte 53,22,34,20
        byte 58,150,34,19
        byte 52,150,34,20
        byte 62,150,34,20
        byte 60,24,36,20
        byte 60,152,36,20
        byte 58,152,36,40
        byte 53,17,29,20
        byte 45,145,29,19
        byte 48,16,36,41
        byte 50,14,154,20
        byte 50,142,154,20
        byte 53,142,154,20
        byte 181,12,29,20
        byte 46,19,159,20
        byte 53,22,34,19
        byte 58,150,34,20
        byte 53,17,29,20
        byte 48,21,29,40
        byte 53,149,29,20
        byte 48,149,29,20
        byte 53,17,29,20
        byte 46,22,34,19
        byte 53,150,34,20
        byte 55,150,34,20
        byte 57,21,161,20
        byte 57,24,29,20
        byte 57,152,29,20
        byte 48,152,29,41
        byte 48,152,29,19
        byte 57,152,29,40
        byte 57,152,29,20
        byte 58,152,29,40
        byte 55,152,29,20
        byte 55,152,29,59
        byte 53,152,29,40
        byte 181,17,29,40
        byte 45,145,29,20
        byte 53,145,29,20
        byte 48,17,29,19
        byte 48,145,29,20
        byte 53,16,36,41
        byte 181,14,154,20
        byte 45,142,154,20
        byte 53,142,154,20
        byte 53,142,154,20
        byte 45,142,154,59
        byte 53,12,29,20
        byte 45,140,29,20
        byte 46,22,34,20
        byte 45,150,34,20
        byte 46,150,34,39
        byte 174,17,34,20
        byte 45,22,34,20
        byte 53,150,34,20
        byte 53,150,34,20
        byte 55,150,34,20
        byte 57,24,29,60
        byte 57,152,29,20
        byte 48,152,29,20
        byte 57,152,29,20
        byte 55,152,29,80
        byte 55,152,29,19
        byte 55,152,29,20
        byte 53,152,29,60
        byte 181,17,29,160
        byte 53,145,29,40
        byte 53,145,29,39
        byte 53,145,29,80
        byte 0,145,29,20
        byte 0,0,29,40
        byte 0,0,0,150        ; three seconds' silence before it goes round again
        byte 0,0,0,0

; the 1812 ditty under the wave banner: melody, bass, inner voice
dittytune
        byte 56,20,0,7
        byte 184,148,36,1
        byte 0,148,164,6
        byte 44,148,164,1
        byte 172,148,39,6
        byte 46,148,167,5
        byte 174,148,0,2
        byte 0,148,0,1
        byte 48,148,44,8
        byte 46,148,39,7
        byte 44,148,36,8
        byte 46,148,39,6
        byte 174,148,0,1
        byte 48,148,44,1
        byte 176,24,172,8
        byte 0,152,172,6
        byte 44,152,39,10
        byte 172,152,0,5
        byte 44,152,36,6
        byte 172,152,0,2
        byte 172,152,37,8
        byte 172,152,36,1
        byte 44,27,164,6
        byte 172,155,34,6
        byte 172,155,0,2
        byte 172,32,0,1
        byte 0,160,0,6
        byte 0,0,0,0

; ------------------------------------------------------------
; showtitletanks   the two players' tanks on the title screen, facing
;                  up, one above the other and centred under the
;                  title: player 1's blue on top, player 2's yellow
;                  below. a flag, for anyone who looks.
;                  the title's rows use no fine scroll, so text column
;                  c sits at sprite x 24+8c and the two line up to the
;                  pixel. the title is 19 characters from column 10,
;                  so its centre is the middle of column 19; the tank
;                  is 16 wide with its barrel on its middle two
;                  columns, so it is centred 8 in. each tank's top sits
;                  on a character row, two rows apart: 14 tall, so a
;                  2-pixel gap between them.
; ------------------------------------------------------------
ttx     = 24+19*8+4-8          ; the middle of column 19, less half a tank
tttop   = 50+5*8               ; blue: one clear row under the title (row 3)
ttlow   = 50+7*8               ; yellow: two rows further down
showtitletanks
        lda #tankptr           ; facing up, treads at rest
        sta $47f8
        sta $47f9
        lda #ttx
        sta $d000
        sta $d002
        lda #tttop             ; player 1, blue, on top
        sta $d001
        lda #ttlow             ; player 2, yellow, underneath
        sta $d003
        lda $d010              ; both left of x 256
        and #%11111100
        sta $d010
        lda $d01c              ; hires, not multicolour
        and #%11111100
        sta $d01c
        lda #6                 ; player 1 dark blue
        sta d027
        lda #7                 ; player 2 yellow
        sta d027+1
        lda d015
        ora #%00000011
        sta d015
        rts
musicend                        ; (the memory check needs to see where this
                                ; block really ends, in case it ever grows)

*=$6d00
; ------------------------------------------------------------
; the bonus drone. after every third wave (not the 99th: the missile
; follows that one) a quadcopter flies about the empty field, very
; fast, for fifteen seconds. shoot it for 1000 points; let it fly into
; a tank and it is lost - no life, no bonus. then the next wave.
;
; states: 0 none, 1 flying, 2 over (a moment for the blast, then
; the next wave), 3 the pause after any stage is cleared. it is drawn in enemy slot 0's place in the sprite
; table - the stage is clear, so nothing else is using it.
; ------------------------------------------------------------
dronespr                       ; two frames: rotors blurred, then blades
        byte $70,$0e,$00,$f8,$1f,$00,$f8,$1f,$00,$f8,$1f,$00,$70,$0e,$00,$04
        byte $20,$00,$03,$c0,$00,$03,$40,$00,$02,$c0,$00,$03,$c0,$00,$04,$20
        byte $00,$70,$0e,$00,$f8,$1f,$00,$f8,$1f,$00,$f8,$1f,$00,$70,$0e,$00
        byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
        byte $88,$11,$00,$50,$0a,$00,$20,$04,$00,$50,$0a,$00,$88,$11,$00,$04
        byte $20,$00,$03,$c0,$00,$03,$40,$00,$02,$c0,$00,$03,$c0,$00,$04,$20
        byte $00,$88,$11,$00,$50,$0a,$00,$20,$04,$00,$50,$0a,$00,$88,$11,$00
        byte $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
droneptr = (dronespr-$4000)/64
dronecol = 13                  ; light green: nothing else on the field is
dronespin = 7                  ; pixels a tick round the rim: a lap in 2.1s
dronehalf = 0                  ; 1 adds a pixel every other tick (7.5)
dronedash = 9                  ; pixels a tick when it flings itself at a
dashhalf = 0                   ; player; 1 adds one every other tick (9.5).
                               ; nothing on the field is faster
spinticks = 50*10              ; ten seconds of laps before the first fling
dashticks = 50*8               ; then eight seconds of flinging
tellticks = 45                 ; it stops dead this long before diving:
                               ; the moment to shoot it
lurkband = 36                  ; a player this close to a side of the rim
                               ; - a square in from its path - keeps it
                               ; off that side
dodgegrace = 40                ; ticks between dodges: without a floor a
                               ; tank simply pointing at the rim pinned it
campdist = 48                  ; a player this close to where it would come
                               ; in is lying in wait: it comes in at the
                               ; centre of the map instead
dfminx = 24                    ; the rim it runs: the field, less its width
dfmaxx = 216
dfminy = 50
dfmaxy = 234
dronebonus = $10               ; bcd hundreds: 1000 points
droneticks = 50*15             ; fifteen seconds
clearpause = 250               ; five seconds' pause after a stage is cleared
reversehold = 20               ; ticks after a turn before an enemy may
                               ; turn straight back (0.4s)
strikespeed = 6                ; pixels a tick the drone strike comes down:
                               ; the sweep takes about two thirds of a second

; called when the stage is clear. carry set: hold the next wave back -
; there is always a pause first, a few seconds with the field empty,
; then either the drone or the next wave
dronecheck
        lda dronestate
        bne @hold             ; already pausing, flying or finishing
        lda #3                ; the pause
        sta dronestate
        lda #clearpause
        sta dronewait
        jsr isdronewave       ; say so, if one is on its way
        bcc @hold
        jsr drawbonusbanner
@hold   sec
        rts

; carry set if this wave ends with the drone: every third wave, but not
; the 99th (the missile follows that one) and never in a duel
isdronewave
        lda duelmode
        bne @no
        lda wave
        cmp #99
        beq @no
@m3     cmp #3
        bcc @r
        sbc #3                ; carry is set here, from the cmp
        jmp @m3
@r      cmp #0
        bne @no
        sec
        rts
@no     clc
        rts

startdrone
        lda #0                ; no helmets in the bonus round: whatever
        sta p1shield          ; protection was left runs out the moment
        sta p2shield          ; the drone arrives, and the flashing
                               ; stops, so a player can see they are
                               ; on their own against it
        lda seed              ; stir in the frame counter: how long the
        eor tick              ; wave took to clear is the one thing a
        sta seed              ; player cannot repeat exactly
        lda #1
        sta dronestate
        lda #<spinticks       ; ten seconds of laps
        sta dronetime
        lda #>spinticks
        sta dronetime+1
        jsr rand256           ; clockwise or anticlockwise, at random, so
        and #%01000000        ; it cannot be learned. bit 6: bit 0 of this
        beq @spinset          ; generator is just the last state's bit 7,
        lda #1                ; so small seeds always gave clockwise
@spinset
        sta dronespinccw
        jsr spinturn          ; and it doubles back now and then
        jsr rimpoint          ; somewhere on the rim to come in at
        jsr camped            ; unless a player is loitering there
        bcc @atrim
        lda #(dfminx+dfmaxx)/2   ; ambushed: come in at the centre of the
        sta dronex               ; map instead, and make for the point
        lda #(dfminy+dfmaxy)/2   ; opposite the one they are watching
        sta droney
        lda #dfminx+dfmaxx
        sec
        sbc dronetx
        sta dronetx
        lda #dfminy+dfmaxy
        sec
        sbc dronety
        sta dronety
        jsr dashsetup
        lda #2                ; phase 2: out to the rim, then laps
        sta dronephase
        rts
@atrim  lda dronetx           ; nobody waiting: come in on the rim
        sta dronex
        lda dronety
        sta droney
        jsr rimedge           ; which edge it landed on
        lda #0
        sta dronephase        ; phase 0: laps
        rts

; ------------------------------------------------------------
; aimedat   is an alive player lined up on the drone - facing it,
;           and within half a tank's width of its line? that is a
;           player about to fire, and the drone turns away.
;   out:  carry set = someone has it lined up
;   uses: a, x, y
; ------------------------------------------------------------
aimedat lda #0                ; dronek: which player, 0 or 1
        sta dronek
@who    ldy dronek            ; y indexes the paired tables (alive,
        lda dronek            ; respawn, facing); x the positions,
        asl                   ; which run x, y, xmsb per player - a
        adc dronek            ; stride of three. (the first version used
        tax                   ; y for both, and read player 1's y as
                               ; player 2's x: the dodge never worked
                               ; for player 2)
        lda p1alive,y
        beq @next
        lda p1respawn,y       ; a tank blowing up aims at nothing
        bne @next
        lda p1facing,y        ; up (0) or down (1): the drone must be in
        cmp #2                ; the same column, and on the side the
        bcs @horiz            ; tank is pointing
        lda p1x,x
        sec
        sbc dronex
        jsr dabs
        cmp #12
        bcs @next
        lda p1facing,y
        bne @down
        lda p1y,x             ; facing up: is it above the tank?
        cmp droney
        bcs @yes
        jmp @next
@down   lda droney            ; facing down: below it
        cmp p1y,x
        bcs @yes
        jmp @next
@horiz  lda p1y,x             ; left (2) or right (3): same row
        sec
        sbc droney
        jsr dabs
        cmp #12
        bcs @next
        lda p1facing,y
        cmp #2
        bne @right
        lda dronex            ; facing left: is it to the left?
        cmp p1x,x
        bcc @yes
        jmp @next
@right  lda p1x,x             ; facing right: to the right
        cmp dronex
        bcc @yes
@next   inc dronek
        lda dronek
        cmp #2
        bne @who
        clc
        rts
@yes    sec
        rts

; ------------------------------------------------------------
; lurked   is a player lying in wait beside a side of the rim - on
;          the field and within lurkband of that side's line? a
;          player parked a square in from the rim, stepping out to
;          fire along it and back, was the way to hunt the drone.
;   in:   a = the side (0 top, 1 right, 2 bottom, 3 left)
;   out:  carry set = someone is there
;   uses: a, x, y, dronek, droneside
; ------------------------------------------------------------
lurked  sta droneside
        lda #0
        sta dronek
@who    ldy dronek
        lda dronek
        asl
        adc dronek
        tax                   ; x: this player's position (stride 3)
        lda p1alive,y
        beq @next
        lda p1respawn,y
        bne @next
        lda droneside
        beq @top
        cmp #1
        beq @right
        cmp #2
        beq @bottom
        lda p1x,x             ; left side
        cmp #dfminx+lurkband
        bcc @yes
        jmp @next
@right  lda p1x,x
        cmp #dfmaxx-lurkband+1
        bcs @yes
        jmp @next
@top    lda p1y,x
        cmp #dfminy+lurkband
        bcc @yes
        jmp @next
@bottom lda p1y,x
        cmp #dfmaxy-lurkband+1
        bcs @yes
@next   inc dronek
        lda dronek
        cmp #2
        bne @who
        clc
        rts
@yes    sec
        rts

; ------------------------------------------------------------
; spinturn   how long until it doubles back: 60 to 187 ticks, so
;            a ten-second lap reverses two or three times at
;            moments the player cannot predict - often enough to
;            fake them out, rare enough not to dither on the spot.
;   uses: a
; ------------------------------------------------------------
spinturn
        jsr rand256
        and #127
        clc
        adc #60
        sta droneturn
        rts

; ------------------------------------------------------------
; rimpoint   a random point on the rim, into dronetx/dronety.
;   uses: a
; ------------------------------------------------------------
rimpoint
        jsr rand256           ; which edge: the top two bits. the low ones
        lsr                   ; are this generator's weak end, and gave
        lsr                   ; only the top and right edges
        lsr
        lsr
        lsr
        lsr
        sta dronetmp
        lsr                   ; edges 0/2 are the top and bottom: x varies
        bcs @vert
@horiz  jsr rand256
        cmp #dfmaxx-dfminx+1
        bcs @horiz
        adc #dfminx
        sta dronetx
        lda #dfminy
        ldx dronetmp
        cpx #2
        bne @hset
        lda #dfmaxy
@hset   sta dronety
        rts
@vert   jsr rand256
        cmp #dfmaxy-dfminy+1
        bcs @vert
        adc #dfminy
        sta dronety
        lda #dfmaxx
        ldx dronetmp
        cpx #1
        beq @vset
        lda #dfminx
@vset   sta dronetx
        rts

; ------------------------------------------------------------
; camped   is either player within campdist of dronetx/dronety -
;          that is, lying in wait for the drone to appear?
;   out:  carry set = yes
;   uses: a
; ------------------------------------------------------------
camped  lda p1alive
        beq @two
        lda p1x
        sec
        sbc dronetx
        jsr dabs
        cmp #campdist
        bcs @two
        lda p1y
        sec
        sbc dronety
        jsr dabs
        cmp #campdist
        bcc @yes
@two    lda p2alive
        beq @no
        lda p2x
        sec
        sbc dronetx
        jsr dabs
        cmp #campdist
        bcs @no
        lda p2y
        sec
        sbc dronety
        jsr dabs
        cmp #campdist
        bcc @yes
@no     clc
        rts
@yes    sec
        rts

; ------------------------------------------------------------
; dabs   |a|, treating a as signed. uses: a
; ------------------------------------------------------------
dabs    cmp #128
        bcc @done
        eor #$ff
        clc
        adc #1
@done   rts

; ------------------------------------------------------------
; rimedge   which edge of the rim the drone is sitting on, into
;           droneedge (0 top, 1 right, 2 bottom, 3 left).
;   uses: a
; ------------------------------------------------------------
rimedge lda droney
        cmp #dfminy
        bne @notop
        lda #0
        sta droneedge
        rts
@notop  cmp #dfmaxy
        bne @side
        lda #2
        sta droneedge
        rts
@side   lda dronex
        cmp #dfminx
        bne @right
        lda #3
        sta droneedge
        rts
@right  lda #1
        sta droneedge
        rts

; ------------------------------------------------------------
; dashsetup   line from the drone to dronetx/dronety, stepped a
;             pixel at a time by dashstep: signs, |dx|, |dy|, the
;             major axis and its error term.
;   uses: a
; ------------------------------------------------------------
dashsetup
        lda #1                ; x step
        sta dronesx
        lda dronetx
        sec
        sbc dronex
        bcs @xpos
        eor #$ff
        clc
        adc #1
        ldx #$ff
        stx dronesx
@xpos   sta dronedx
        lda #1                ; y step
        sta dronesy
        lda dronety
        sec
        sbc droney
        bcs @ypos
        eor #$ff
        clc
        adc #1
        ldx #$ff
        stx dronesy
@ypos   sta dronedy
        lda dronedx           ; the major axis, and err = major/2
        cmp dronedy
        bcs @xmajor
        lda #1
        sta dronemajory
        lda dronedy
        jmp @err
@xmajor lda #0
        sta dronemajory
        lda dronedx
@err    lsr
        sta droneerr
        rts

; ------------------------------------------------------------
; dashstep   one pixel along the dash line, which runs on through
;            the target to the field's edge. carry set at the edge.
;   uses: a
; ------------------------------------------------------------
dashstep                       ; the line runs on THROUGH the target to the
                               ; edge of the field: stopping at the spot the
                               ; player had been left the drone vanishing in
                               ; mid-air a tank's width short of anyone who
                               ; had driven on along its line
        lda dronemajory
        bne @ymaj
        lda dronex            ; x is the major axis: always steps
        clc
        adc dronesx
        sta dronex
        lda droneerr
        clc
        adc dronedy
        bcs @xstep            ; past 255: certainly a step on y is due.
        cmp dronedx           ; (ignoring this carry lost the step on a
        bcc @done             ; long diagonal dive, so the drone never met
@xstep  sbc dronedx           ; its target and flew off round the screen)
        sta droneerr
        lda droney
        clc
        adc dronesy
        sta droney
        jmp dashbounds
@ymaj   lda droney
        clc
        adc dronesy
        sta droney
        lda droneerr
        clc
        adc dronedx
        bcs @ystep            ; the same for a y-major line
        cmp dronedy
        bcc @done
@ystep  sbc dronedy
        sta droneerr
        lda dronex
        clc
        adc dronesx
        sta dronex
        jmp dashbounds
@done   sta droneerr
        jmp dashbounds


; ------------------------------------------------------------
; dashbounds   the end of every dash step: the drone never leaves
;              the field. at an edge it stops, as if it had arrived,
;              and the next fling lines up afresh.
;   out:  carry set = stopped at an edge
;   uses: a
; ------------------------------------------------------------
dashbounds
        lda dronex
        cmp #dfminx
        bcc @outx
        cmp #dfmaxx+1
        bcs @outx
        lda droney
        cmp #dfminy
        bcc @outy
        cmp #dfmaxy+1
        bcs @outy
        clc
        rts
@outx   lda dronex            ; clamp it back in, and stop
        cmp #128
        bcs @highx
        lda #dfminx
        jmp @setx
@highx  lda #dfmaxx
@setx   sta dronex
        sec
        rts
@outy   lda droney
        cmp #142
        bcs @highy
        lda #dfminy
        jmp @sety
@highy  lda #dfmaxy
@sety   sta droney
        sec
        rts
; ------------------------------------------------------------
; flingat   pick a player and lock the dash line onto them. carry
;           clear if neither is alive to fling at.
;   uses: a
; ------------------------------------------------------------
flingat lda p1alive           ; a target is a tank on the field: alive
        beq @p1out            ; and not in the middle of respawning
        lda p1respawn
        beq @p1in
@p1out  lda #0
        beq @p1set
@p1in   lda #1
@p1set  sta dronetmp          ; player 1 available?
        lda p2alive
        beq @p2out
        lda p2respawn
        beq @p2in
@p2out  lda #0
        beq @p2set
@p2in   lda #1
@p2set  ora dronetmp
        bne @someone
        clc
        rts
@someone
        lda dronetmp          ; both on the field: choose at random
        beq @usep2
        lda p2alive
        beq @usep1
        lda p2respawn
        bne @usep1
        jsr rand256
        and #%01000000        ; bit 6, as above
        bne @usep2
@usep1  lda p1x
        sta dronetx
        lda p1y
        sta dronety
        jmp @lock
@usep2  lda p2x
        sta dronetx
        lda p2y
        sta dronety
@lock   jsr dashsetup
        sec
        rts

; every tick, from the main loop
updatedrone
        lda dronestate
        bne @on
        rts
@on     cmp #3
        bne @notpause
        dec dronewait         ; the pause after a stage is cleared
        bne @paused
        jsr isdronewave       ; over: the drone, or straight on to
        bcc @nodrone          ; the next wave
        jsr clearbonusbanner
        jmp startdrone
@nodrone
        lda #0
        sta dronestate
        jmp newwave
@paused rts
@notpause
        cmp #1
        beq @fly
        jsr anthemrun         ; the fanfare, if the drone was shot down
        dec dronewait         ; over: a moment for the blast, then on
        bne @wait
        lda #0
        sta dronestate
        jmp newwave
@wait   rts
@fly    lda dronetime         ; the phase clock
        ora dronetime+1
        bne @tick
        lda dronephase        ; laps over: stop dead for a moment -
        beq @poise            ; the tell - then fling itself at a
        cmp #3                ; player. after the flinging, it goes
        beq @dive
        jmp @leave
@poise  lda #3                ; the tell: stopped, and flashing
        sta dronephase
        lda #<tellticks
        sta dronetime
        lda #>tellticks
        sta dronetime+1
        jmp @hits
@dive   lda #1
        sta dronephase
        lda #<dashticks
        sta dronetime
        lda #>dashticks
        sta dronetime+1
        jsr flingat
        bcc @leave
        jmp @hits
@leave  lda #2                ; time up, or nobody to fling at
        sta dronestate
        lda #25
        sta dronewait
        rts
@tick   lda dronetime
        bne @lo
        dec dronetime+1
@lo     dec dronetime
        lda dronephase
        beq @lap
        cmp #3
        bne @notell
        jmp @hits             ; the tell: it does not move at all
@notell cmp #2
        beq @outbound
; --- flinging itself at a player -----------------------------
        lda tick              ; dronedash pixels this tick, plus one
        and #dashhalf         ; every other tick if dashhalf is 1
        clc
        adc #dronedash
        tax
@dashl  jsr dashstep
        bcs @refling
        dex
        bne @dashl
        jmp @hits
@refling
        jsr dronehits         ; the dive is over: did it end on a tank?
        lda dronestate        ; (or a shell find it on the way in)
        cmp #1
        bne @over             ; it did - that was the end of it
        jmp @leave            ; it missed: one dive, and the round is over
@over   rts
; --- out from the centre to the rim, when it came in ambushed --
@outbound
        ldx #dronedash
@outl   jsr dashstep
        bcs @atrim
        dex
        bne @outl
        jmp @hits
@atrim  jsr rimedge           ; on the rim now: start lapping, with
        lda #0                ; what is left of the lap clock
        sta dronephase
        jmp @hits
; --- a lap of the rim ----------------------------------------
@lap    lda dronedodge        ; a moment's grace after a dodge, so a
        beq @maydodge         ; tank pointing its way cannot pin it
        dec dronedodge
        jmp @turncheck
@maydodge
        jsr aimedat           ; someone lining up a shot? turn away
        bcc @turncheck
        lda dronespinccw
        eor #1
        sta dronespinccw
        lda #dodgegrace
        sta dronedodge
        jsr spinturn          ; and the random reversal clock restarts
        jmp @spun
@turncheck
        dec droneturn         ; time to double back anyway?
        bne @spun
        lda dronespinccw
        eor #1
        sta dronespinccw
        jsr spinturn
@spun   lda tick              ; the step round the rim: dronespin, plus
        and #dronehalf        ; one every other tick if dronehalf is 1
        clc                   ; (a half step: 4.5 was tried)
        adc #dronespin
        sta dronestep
        ldx droneedge
        lda droneedge
        and #1
        bne @vertical
        lda dronex            ; top or bottom edge: x runs
        ldy dronespinccw
        bne @hleft
        cpx #0                ; clockwise: right along the top, left
        beq @hright           ; along the bottom
        jmp @hleftc
@hleft  cpx #0                ; anticlockwise: the other way about
        beq @hleftc
@hright clc
        adc dronestep
        cmp #dfmaxx
        bcc @hset
        lda #dfmaxx
        jmp @hset
@hleftc sec
        sbc dronestep
        cmp #dfminx
        bcs @hset
        lda #dfminx
@hset   sta dronex
        jmp @corner
@vertical
        lda droney            ; left or right edge: y runs
        ldy dronespinccw
        bne @vup
        cpx #1                ; clockwise: down the right edge, up the
        beq @vdown            ; left one
        jmp @vupc
@vup    cpx #1
        beq @vupc
@vdown  clc
        adc dronestep
        cmp #dfmaxy
        bcc @vset
        lda #dfmaxy
        jmp @vset
@vupc   sec
        sbc dronestep
        cmp #dfminy
        bcs @vset
        lda #dfminy
@vset   sta droney
@corner lda dronex            ; a corner is both axes against a limit:
        cmp #dfminx           ; turn onto the next edge
        beq @xlim
        cmp #dfmaxx
        beq @xlim
        jmp @hits
@xlim   lda droney
        cmp #dfminy
        beq @ylim
        cmp #dfmaxy
        beq @ylim
        jmp @hits
@ylim   lda droneedge         ; the side it would turn onto next
        ldy dronespinccw
        bne @nextccw
        clc
        adc #1
        jmp @nextside
@nextccw
        sec
        sbc #1
@nextside
        and #3
        sta dronenext
        jsr lurked            ; someone waiting beside it? then turn
        bcc @turn             ; back along this side instead
        lda dronespinccw
        eor #1
        sta dronespinccw
        jmp @hits
@turn   lda dronenext
        sta droneedge
@hits   jmp dronehits

; a player's shell inside the drone's 16x16, or a tank on top of it
dronehits
        ldx #3
@shell  lda pbactive,x
        beq @nexts
        lda pbx,x             ; the shell's own pixel, less the drone's
        sec                   ; left edge: 0-15 is inside
        sbc dronex
        cmp #16
        bcs @nexts
        lda pby,x
        sec
        sbc droney
        cmp #16
        bcs @nexts
        lda #0                ; hit: the shell is spent...
        sta pbactive,x
        ldy #0                ; ...and whoever fired it scores
        cpx #2
        bcc @p1
        ldy #1
@p1     sty dronetmp          ; whose shell it was
        lda #dronebonus
        jsr addhundreds
        ldy dronetmp          ; ...and a spare life for them, up to the
        bne @lifep2           ; nine the sidebar can show
        lda p1lives
        cmp #9
        bcs @lifedone
        inc p1lives
        jmp @lifedone
@lifep2 lda p2lives
        cmp #9
        bcs @lifedone
        inc p2lives
@lifedone
        jsr marksidebar
        jsr droneblast        ; the blast...
        jmp dittystart        ; ...and the 1812: it plays on through the
                               ; moment after the hit and under the next
                               ; wave's banner
@nexts  dex
        bpl @shell
        lda dronephase        ; while it laps the rim it is out of
        cmp #1                ; reach - a tank can only be crashed
        bne @none             ; into once it dives. (the rim runs
                               ; along the players' own spawn row:
                               ; without this it flew into a parked
                               ; player two seconds in, every time)
        lda p1alive           ; a tank in its way: it takes the tank
        beq @t2               ; with it, and the bonus is gone. a tank
        lda p1respawn         ; still blowing up is not there: hittank1
        bne @t2               ; would ignore it and the life put back
        lda p1x               ; below would be a free one
        sec
        sbc dronex
        clc
        adc #13
        cmp #27
        bcs @t2
        lda p1y
        sec
        sbc droney
        clc
        adc #13
        cmp #27
        bcs @t2
        lda p1star            ; the tank goes up, but the bonus round
        sta dronetmp          ; costs nothing: the life put here is the
        inc p1lives           ; one hittank1 takes, and the gun upgrade
        jsr hittank1          ; it clears is put straight back
        lda dronetmp
        sta p1star
        jmp droneblast
@t2     lda p2alive
        beq @none
        lda p2respawn
        bne @none
        lda p2x
        sec
        sbc dronex
        clc
        adc #13
        cmp #27
        bcs @none
        lda p2y
        sec
        sbc droney
        clc
        adc #13
        cmp #27
        bcs @none
        lda p2star            ; as above: no life and no upgrade lost
        sta dronetmp
        inc p2lives
        jsr hittank2
        lda dronetmp
        sta p2star
        jmp droneblast
@none   rts

droneblast
        lda droney            ; the burst on the cells under the drone
        sec
        sbc #50
        lsr
        lsr
        lsr
        sta trow
        lda dronex
        sec
        sbc #24
        lsr
        lsr
        lsr
        sta tcol
        jsr spawnexplosion
        jsr playexplosion
        lda #2
        sta dronestate
        lda #50               ; a second to see it go
        sta dronewait
        rts

; from buildsprites: the drone in enemy slot 0's place
; ------------------------------------------------------------
; strikesprites   during a drone strike, draw a blue drone diving
;                 on each tank still standing. they borrow the
;                 display places of enemy bullets that are not in
;                 flight: a bullet is never hidden by one, and if
;                 no place is spare the tank still dies.
;   uses: a, x, y
; ------------------------------------------------------------
strikesprites
        lda strikeon
        bne @on
        rts
@on     ldy #4                ; the first candidate place
        ldx #0
@tank   lda moactive,x        ; a drone for every tank still standing
        beq @next
@find   cpy #8
        bcs @done             ; no places left: it still dies, unseen
        lda moactive,y        ; a bullet in flight keeps its place
        beq @place
        iny
        jmp @find
@place  lda mox,x             ; the drone dives down the tank's column
        sta objx,y
        lda strikey
        sta objy,y
        lda tick              ; rotors, a frame every two ticks
        lsr
        and #1
        clc
        adc #droneptr
        sta objp,y
        lda #6                ; blue: ours, not theirs
        sta objc,y
        lda #0                ; it flies: never behind the trees
        sta objpri,y
        iny
@next   inx
        cpx #4
        bne @tank
@done   rts

dronesprite
        lda dronestate
        cmp #1
        bne @no
        lda dronex
        sta objx
        lda droney
        sta objy
        lda tick              ; the rotors: a frame every two ticks
        lsr
        and #1
        clc
        adc #droneptr
        sta objp
        ldy dronephase        ; poised to dive: flashing white, so the
        cpy #3                ; player can see it coming. (the test of
        bne @plain            ; tick must not be left in a: that drew
        lda tick              ; the drone black every other frame)
        and #2
        bne @white
@plain  lda #dronecol
        jmp @col
@white  lda #1
@col    sta objc
        lda #0                ; it flies: never behind the trees
        sta objpri
@no     rts

dronestate byte 0
dronetime byte 0,0
dronewait byte 0
droneturn byte 0
dronex  byte 0
droney  byte 0
dronephase byte 0        ; 0 lapping the rim, 1 flinging, 2 out from the centre
dronespinccw byte 0      ; which way round it laps, chosen at random
droneedge byte 0         ; 0 top, 1 right, 2 bottom, 3 left
dronesx byte 0           ; the dash line: steps, lengths, major axis, error
dronesy byte 0
dronedx byte 0
dronedy byte 0
dronemajory byte 0
droneerr byte 0
dronetmp byte 0
dronestep byte 0         ; this tick's step round the rim, 4 or 5
dronedodge byte 0        ; ticks before it will dodge an aim again
dronek  byte 0           ; the player being looked at, 0 or 1
droneside byte 0         ; the side of the rim being looked at
dronenext byte 0         ; the side it would turn onto next
strikeon byte 0          ; a drone strike in progress
strikey byte 0           ; how far down the field its dive has come
strikeby byte 0          ; the player who called it in
dronetx byte 0
dronety byte 0

; the drone on its briefing page, where the tanks stand on theirs:
; centred, its foot two clear rows above the name. the drone is 16
; tall to the tank's 14, so it sits 2 pixels higher to finish level
showdronesprite
        lda #droneptr
        sta $47f8
        lda #dronecol
        sta d027
        lda #24+19*8
        sta $d000
        lda #50+8*8
        sta $d001
        lda $d010
        and #%11111110
        sta $d010
        lda d015
        ora #%00000001
        sta d015
        rts

; every briefing tick: on the drone's page, spin its rotors
briefdrone
        lda attridx
        cmp #10
        bne @no
        lda tick
        lsr
        and #1
        clc
        adc #droneptr
        sta $47f8
@no     rts

