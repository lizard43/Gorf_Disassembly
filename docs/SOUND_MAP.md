<!-- SOUND_MAP.md -->
# Gorf Program 2 Astrocade Sound Map

This document describes the non-speech sound system in the English Gorf Program 2 ROM: the two Astrocade sound engines, Gorf's resident music processor, the score bytecode used to program the hardware, and the complete set of independent ROM score launch points identified in the Program 2 game code.

SC-01 speech is a separate subsystem and is documented in `SPEECH_MAP.md`. Gorf non-speech audio is synthesized by the Astrocade tone/noise hardware from ROM score programs; these are music-processor bytecode streams, not PCM samples.

## Sound architecture

Gorf has two Astrocade sound engines. Each engine exposes the same eight logical sound registers, and Gorf maintains a separate 48-byte music-processor work array for each engine.

| Engine | Sound registers | Block port | Gorf work array |
| --- | --- | --- | --- |
| Primary | `$10-$17` | `$18` | `$D0B1-$D0E0` |
| Secondary | `$50-$57` | `$58` | `$D0E1-$D110` |

The score bytecode uses logical sound-register numbers `$10-$17`. Gorf's `portout` routine translates those logical numbers through the selected work array's `SOUNDBOX` field. The same score operation can therefore address either physical engine without embedding a separate set of `$50-$57` opcodes in the score.

`MUSICFLAG` at `$D0AF` is the global music-service enable. When it is zero, Gorf does not advance either music processor.

## Astrocade sound registers

| Logical register | Primary | Secondary | Function |
| ---: | ---: | ---: | --- |
| `$10` | `$10` | `$50` | Master oscillator divider shared by Tone A, Tone B, and Tone C |
| `$11` | `$11` | `$51` | Tone A divider |
| `$12` | `$12` | `$52` | Tone B divider |
| `$13` | `$13` | `$53` | Tone C divider |
| `$14` | `$14` | `$54` | Vibrato: speed in bits 7-6, depth in bits 5-0 |
| `$15` | `$15` | `$55` | Tone C volume in bits 3-0; master-modulation selection and noise enable in the upper control bits |
| `$16` | `$16` | `$56` | Tone A volume in bits 3-0; Tone B volume in bits 7-4 |
| `$17` | `$17` | `$57` | Noise control; upper nibble supplies audible noise level and the byte also participates in noise modulation |

For an unmodulated tone, the nominal divider relationship is:

```text
frequency = chip clock / (2 * (master + 1) * (tone divider + 1))
```

The block ports `$18` and `$58` allow the corresponding eight-register set to be transferred as one descending register block, `$17` through `$10` or `$57` through `$50`.

## Gorf music processor

The Program 2 ROM contains a software music processor that interprets compact score bytecode and writes the selected Astrocade engine. The important resident entry points are:

| Address | Name | Function |
| ---: | --- | --- |
| `$0B85` | `ENDMUS` | Stopped/end score marker used as the idle music PC |
| `$0B86` | `emusic` | Stop/reset one music processor and silence its eight hardware registers |
| `$0F7E` | `busaround` | Service the primary and secondary music processors |
| `$0FAC` | `bmusic` | Begin a score only if the selected processor is idle |
| `$0FC2` | `pmusic` | Stop/replace the selected score, then begin the new score |
| `$0FDB` | `mmusic` | Begin a score with a caller-supplied multiple value |
| `$0FF0` | `mpmusic` | Replace a score and begin with a caller-supplied multiple value |

### TERSE interface

Gorf exposes the native routines through separate primary and secondary TERSE words:

| Primary | Secondary | Native operation |
| --- | --- | --- |
| `_EMUSIC` | `_E2MUSIC` | `emusic` |
| `_BMUSIC` | `_B2MUSIC` | `bmusic` |
| `_PMUSIC` | `_P2MUSIC` | `pmusic` |
| `_MMUSIC` | `_M2MUSIC` | `mmusic` |
| `_MPMUSIC` | `_MP2MUSIC` | `mpmusic` |

`_EMUSIC` initializes `SOUNDBOX` to `$18`; `_E2MUSIC` initializes it to `$58`. Gorf's `SHUTUP` word executes both stop operations.

### Start and stop behavior

`bmusic` is the non-replacing start. It checks the selected processor's active state and leaves an existing score alone. When idle, it initializes the processor and installs the requested score as both the current music PC and start PC.

`pmusic` is the replacing start. It calls `emusic` for the selected processor before installing the new score.

`mmusic` and `mpmusic` are the corresponding forms that take the multiple value from the caller. The ordinary `bmusic` and `pmusic` paths initialize that value to one.

`emusic` is the authoritative native stop. It sets the music PC to `ENDMUS`, clears the active music state, reads the processor's `SOUNDBOX` selector, and outputs zero to all eight registers of that engine.

## Music service path

Starting a score initializes the selected processor; it does not by itself advance the score. Gorf advances sound by calling `busaround` at `$0F7E` from foreground game code.

`busaround`:

1. checks `MUSICFLAG`;
2. services the primary work array at `$D0B1`;
3. services the secondary work array at `$D0E1`;
4. returns to the game.

The music service updates timers and motion fields, interprets score operations when the processor is ready for another state transition, and writes the resulting values to the selected Astrocade sound engine.

## Music-processor work arrays

The two 48-byte work arrays have the same layout. The fields most important to score execution are:

| Offset | Field | Purpose |
| ---: | --- | --- |
| `+$00` | `MUSPC` | Current score bytecode address |
| `+$02` | `STARTPC` | Score start address used by repeat control |
| `+$04` | `SOUNDBOX` | Engine selector: `$18` primary or `$58` secondary |
| `+$07` | `MULTIPLE` | Repeat/multiple count used by score control |
| `+$08` | active/replacement state | Tested by the non-replacing `bmusic`/`mmusic` paths |
| `+$2E` | `NOTETIMER` | Score timing counter |
| `+$2F` | `MST` | Music state-transition flag |

The remaining fields hold ramble, movement, volume, noise, modulation, and tracker state used by the score opcodes below.

## Gorf score bytecode

A Gorf score is data for the resident music processor, not Z80 machine code. The current release ROM contains a 28-entry opcode vector table, `OPADDRESSES`, covering `$00-$1B`.

| Opcode | Handler | Operation |
| ---: | --- | --- |
| `$00` | `randomnotes` | Produce a randomized register value within score-supplied bounds |
| `$01` | `loadtimer` | Load `NOTETIMER` |
| `$02` | `contjump` | Continue at an absolute score address |
| `$03` | `quitjump` | Score control operation used by the resident end path |
| `$04` | `quityet` | Decrement `MULTIPLE`; repeat from `STARTPC` or call `emusic` |
| `$05` | `ramblin` | Configure downward ramble state |
| `$06` | `rampin` | Configure upward ramble state |
| `$07` | `musicin` | Music-generator opcode; Program 2 release implementation is a `RET` |
| `$08` | `ramble_on` | Enable ramble |
| `$09` | `ramble_off` | Disable ramble |
| `$0A` | `limitramble` | Set ramble limit/count state |
| `$0B` | `stepmovin` | Configure stepped movement |
| `$0C` | `lowmovin` | Configure low-limit movement |
| `$0D` | `highmovin` | Configure high-limit movement |
| `$0E` | `tbmovin` | Configure time-base movement |
| `$0F` | `nomovin` | Configure noise movement and initial noise state |
| `$10` | `mastart` | Write the master oscillator register |
| `$11` | `opport` | Write logical register `$11` |
| `$12` | `opport` | Write logical register `$12` |
| `$13` | `opport` | Write logical register `$13` |
| `$14` | `opport` | Write logical register `$14` |
| `$15` | `mcmovin` | Write packed Tone C/modulation control through Gorf's volume path |
| `$16` | `abvolin` | Write packed Tone A/B volume through Gorf's volume path |
| `$17` | `noiseport` | Write noise control |
| `$18` | `soundmovin` | Stereo sound-movement opcode; Program 2 release implementation is a `RET` |
| `$19` | `panlimitcountin` | Stereo pan-limit opcode; Program 2 release implementation is a `RET` |
| `$1A` | `volmovin` | Configure volume movement |
| `$1B` | `mohittin` | Configure master-oscillator thumper/synchronization state |

The opcode table defines the interpretation of score bytes. A ROM range used as a music score must not be treated as Z80 instructions merely because the same bytes happen to form valid Z80 opcodes.

### Demo-mode volume handling

`abvolin` and `mcmovin` pass their packed volume values through `halfvols`. When `DEMOMODE` is non-zero, Gorf reduces the packed output levels before writing the sound hardware. This is native game behavior.

## Program 2 embedded sound library

A complete static audit of the Program 2 application code identifies six independent score launch points: two on the primary engine and four on the secondary engine. These are addresses that game code actually supplies to a primary or secondary music start routine. Internal `contjump`, repeat, and other control-flow destinations inside a score are part of that score and are not separate library entries unless game code launches them independently.

| Score | Engine | Start | Proven game path |
| ---: | --- | --- | --- |
| `$1354` | Secondary | `_B2MUSIC` / `bmusic` | `W_136D` supplies `$1354` to `_B2MUSIC` |
| `$136A` (`AM_FX`) | Primary | `pmusic` | `AM_TALK` selects `$D0B1` and starts `AM_FX` with `pmusic` |
| `$2669` | Primary | `bmusic` | Native Program 2 caller selects `$D0B1` and jumps to `bmusic` |
| `$27A1` | Secondary | `bmusic` | Native Program 2 caller selects `$D0E1` and jumps to `bmusic` |
| `$8BA0` | Secondary | `pmusic` | Native Program 2 caller selects `$D0E1` and calls `pmusic` |
| `$9786` | Secondary | `bmusic` | Native Program 2 caller selects `$D0E1` and jumps to `bmusic` |

The Program 2 application code has no additional independent calls that supply a different score root to `bmusic`, `pmusic`, `mmusic`, `mpmusic`, or their TERSE primary/secondary wrappers. Sound-register writes outside initialization are produced by the resident music processor rather than by a separate application-level sound-effect writer.

All six launch points have been audibly verified with the English Program 2 ROM on MAME 0.289 using their mapped engine and native start primitive.

Only `$136A` has a recovered semantic score label in the current source: `AM_FX`. The other roots remain address-named because assigning gameplay names without source or runtime proof would overstate the evidence.

## `$1354` and `AM_FX` at `$136A`

The `$1354` score is explicitly represented as music data in the recovered Program 2 source. `AM_FX` is a short entry that transfers control into the same score body at `$1356`.

### Raw score bytes

```text
$1354  14 86 10 10 06 10 3C 01 03 13 5E 12 96 11 7E 16
$1364  FF 15 0F 01 40 04

$136A  02 56 13
```

### Decode

| Address | Bytes | Score operation | Effect |
| ---: | --- | --- | --- |
| `$1354` | `14 86` | `$14` `opport` | Write vibrato control `$86` |
| `$1356` | `10 10` | `$10` `mastart` | Write master oscillator `$10` |
| `$1358` | `06 10 3C 01 03` | `$06` `rampin` | Configure ramble limits, step, and timebase |
| `$135D` | `13 5E` | `$13` `opport` | Tone C divider `$5E` |
| `$135F` | `12 96` | `$12` `opport` | Tone B divider `$96` |
| `$1361` | `11 7E` | `$11` `opport` | Tone A divider `$7E` |
| `$1363` | `16 FF` | `$16` `abvolin` | Tone A/B packed volume `$FF` |
| `$1365` | `15 0F` | `$15` `mcmovin` | Tone C/modulation value `$0F` |
| `$1367` | `01 40` | `$01` `loadtimer` | Load `NOTETIMER=$40` |
| `$1369` | `04` | `$04` `quityet` | Complete or repeat according to `MULTIPLE` |
| `$136A` | `02 56 13` | `$02` `contjump` | Continue at `$1356` |

The two launch points therefore share the score body from `$1356`. `$1354` executes the initial `$14=$86` vibrato write first; `AM_FX` enters at `$1356` and omits it. Engine selection comes from the caller, not the score bytes: `$1354` is launched on the secondary engine, while `AM_FX` is launched on the primary engine.

## Source authority

The map uses the following evidence order:

1. Program 2 release ROM bytes and addresses in `Gorf_Disassembly.asm`.
2. Embedded GORFOS/TERSE source text when it matches the release implementation.
3. Direct Program 2 call sites for score address, engine selection, and start primitive.
4. Bally/Astrocade hardware and resident-ROM documentation for the sound registers and music-processor model.
5. Runtime verification against the English Program 2 ROM.

Address-derived names are retained where the game source does not establish a semantic event name.
