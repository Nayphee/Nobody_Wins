# Nobody Wins

A tank game for the Commodore 64, in the mould of Namco's *Battle City*: defend your reactor
against waves of enemy tanks across 35 stages. It started out as an attempt at a quick and dirty
clone, but the longer the game development went on, the more I noticed some similarities to real
life, and adjustments were made.

The title is a dig at war games like *Who Dares Wins*. "Who Dares Dies" was a working title, until
I realized that the reality was worse.

It's a 27,840-byte program, 11,359 lines of 6502 assembly, slopped together in about a week.
Claude wrote the code. I did the directing, AI jockeying and meat proxying.

## The game

Each wave sends twenty tanks at you, in four kinds: light tanks, fast armoured cars, rapid-fire
tanks, and heavies that take four hits. Brick can be shot away, steel can't, water stops tanks but
not shells, forest hides everything, and ice keeps you sliding. Power-ups upgrade your gun,
shield you, freeze the enemy, armour your reactor in steel, give you a life, or call in a drone
strike that clears the field.

There are three modes: one player, two-player co-op sharing one reactor, and a versus duel with
nine lives each. The duel has an "interesting" game mechanic to prevent your opponent from
winning.

The stages repeat after 35, with every enemy tank promoted a grade on each pass, all the way to
wave 99, where the game will finally end. I doubt the player will get to the end without
cheating, but players are a resourceful and clever lot - so a surprise ending was necessary.

## Why

The goal was to push the limits of what AI slop I could produce on the C64. In particular, I
wanted to get it to handle sprite multiplexing, which it did after getting tips from Codebase64
and from the demo *Nine*, which it decompiled to learn a few extra tricks. *Nine* is in the
public domain, to the best of anyone's knowledge.

> **Claude says:** the C64 has eight hardware sprites. Multiplexing shows more moving objects
> than that by reusing each sprite further down the screen while the picture is being drawn. The
> game sorts every tank and shell by height each frame and hands the sprites out from the top
> down, from an interrupt timed to the raster beam.

## How it was made

I used Claude like a Commodore 64 game construction kit. It's not SEUCK, but a different kind of
construction kit. I described what I wanted, played each build, and reported what felt wrong.
Claude wrote the assembly, the level scripts and the tests.

When I asked Claude to look at the NES ROM of *Battle City*, it refused, and when I wanted to use
the Ingsoc anthem from *1984*, it complained about copyright. And so the legality of the end
result was preserved, without even looking at anyone's copyrighted works.

> **Claude says:** I never ran the game on a C64. Every change was assembled by a small Python
> two-pass assembler and exercised in a Python 6502 simulator that drives the game's own
> per-frame routines: put a tank on the field, call `updateenemies`, read what happened. That
> grew into a 30-test regression suite, plus a 17-part test of the bonus round alone, run after
> every change. Alongside it: a pace test, timing how long enemies take to reach the reactor over
> five seeded runs; a level validator; a memory-map checker; and scans for duplicate labels,
> registers clobbered across subroutine calls, and dead code. Three builds come out of the same
> source: the game, an ending test that skips straight to the end, and a bonus-round test in
> which every wave is a drone fight.

## The stages

Every stage started as a sentence or a sketch from me, describing a shape and what it should be
made of. For some, I marked my changes on a screenshot. You'll have to play them to see what they
are.

> **Claude says:** each stage is a short Python script that prints the map, checks that every
> part of it can be reached and that no player starts walled in, and packs it into 72 bytes: one
> number per block of a 13 × 11 grid. Two of the sixteen possible numbers are half-steel blocks,
> added so that a letter E drawn in steel could have its middle bar in the middle.
>
> The stages are shaped by one habit of the enemy AI: a tank blocked by brick shoots it. A maze of
> brick is no maze to a tank, so on the brick maze I put steel along the cheapest route a tank
> could drill, until drilling stopped being the quick way down. The opposite fault was steel in
> the reactor's own column, with a tank facing it and nowhere to go, which trapped tanks for
> minutes on more than one stage. So stages were timed with the pace test before they went in.

## The music

The anthem on the title screen began as a track I got Suno to compose. I was going to use
Dominic Muldowney's "Oceania, 'Tis for Thee", the Ingsoc anthem from *1984*, but Claude advised
against it on copyright grounds. This turned out to be a good decision, because Suno's PRNG-based
composition turned out to be pretty good, and we wouldn't have had it at all otherwise. Claude
listened to it, turned it into SID format, and put the result into the game. The rest of the music is
Tchaikovsky: a bit of the *1812 Overture* plays each time a new wave is announced.

> **Claude says:** I worked out the recording's melody, bass line and chords, and wrote them out
> as note data for a three-voice SID player of my own: the melody on the first voice, the bass on
> the second, and the chords as a fast arpeggio on the third, the usual C64 way of getting
> harmony out of three voices. It's timed to the PAL frame rate of 50.1245 frames a second, and
> notes run into one another without a gap unless the same pitch is struck twice, because gapping
> every note sounded choppy. It also exists as a standalone `.sid` file of 1,752 bytes that plays
> in any SID player.

## The bonus round

Every third wave ends with a bonus round and an enemy drone, worth 1,000 points and an extra life
to whoever shoots it down. It's fast and it has a few tricks. I had it made faster, round after
round, until I could only hit it occasionally, and how I do that is for you to work out. Players
will struggle to solve this one, which is the point.

In reality, drones are a tank's real weakness. And the most powerful thing you can pick up in
this game is a drone strike.

## Things that went wrong

Some of these the tests found. Some I found by playing: player 2 couldn't pick up items, player
2's score carried over into the next game, the tanks dithered back and forth, and I saw the drone
miss a tank and wrap round to the top of the screen.

> **Claude says:** the causes, roughly in the order they turned up.
>
> - **Unlimited shells.** A second `@canfire` label in the firing routine sent the reload check to
>   the wrong place. The assembler used to accept a label defined twice; now it refuses, and the
>   day that check went in it found a leftover second copy of a drone routine.
> - **Enemies aiming a cell to the right.** The AI compared a tank's left edge with the reactor's
>   centre. In open ground nobody would notice; in a corridor one block wide, a tank shuffled
>   back and forth for ever trying to reach a spot it couldn't occupy.
> - **A drone that ignored player 2.** Player positions are stored three bytes apart, and one of
>   the drone's routines read them one byte apart, so it looked for player 2 at player 1's
>   coordinates.
> - **A drone that flew off round the screen.** It steers along straight lines using a one-byte
>   error count, which overflowed on long diagonals, so it missed its target, left the field and
>   wrapped round to the far side.
> - **A free life.** A drone meeting a tank that was already exploding handed out a life by
>   mistake.
> - **The second joystick.** The game writes `$FF` to `$DC00` before reading it, which is correct
>   on a real C64 and overwrites whatever a simulated joystick had put there. For three sessions,
>   every test drove player 1 only.
> - **Player 2 couldn't pick up items.** The pickup code noted player 2 as the taker, then never
>   collected the item. My tests had called the power-up effects directly and skipped that step.
> - **Player 2's score carried over.** Only player 1's score was cleared at the start of a game,
>   a leftover from when the two players shared one score.
> - **Tanks dithering.** Late in the game, tanks rethought their direction every few frames and
>   reversed several times a second. An earlier fix had banned reversing outright and broken one
>   of the water stages, where wandering back is how a tank finds a bridge it has driven past. The
>   version in the game refuses a reversal for 0.4 seconds after any turn, which cut the
>   dithering to a third and left every stage passable.

The pace test could tell us how long the enemies took to reach the reactor. It couldn't tell us
whether a stage was tense or just slow, or whether the drone was a challenge or a nuisance. That's
a human job, because, as I have learnt, AIs have no idea what "fun" feels like.

## Known quirks

- The game's font has no full stop, comma, apostrophe, quote mark or question mark, so those show
  up as gaps in the scrolling message.
- The second joystick port and the scroller's raster timing can't be proven in the simulator.
  They need a real machine or an emulator.

## Building

    python3 tools/asm6502.py source/nobodywins.asm -o nobodywins.prg

The assembler is a small Python script and needs nothing beyond Python 3. Load `nobodywins.prg`
on a C64 or in VICE and type `RUN`.
