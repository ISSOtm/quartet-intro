
INCLUDE "hardware.inc/hardware.inc"
INCLUDE "res/syms.asm"

INCLUDE "res/text.inc"
INCLUDE "res/winx.inc"


OAM_SWAP_SCANLINE equ 24

LINE1_Y equ 8
LINE2_Y equ 26
LINE3_Y equ 44


lb: MACRO
	assert (\2) < 256
	assert (\3) < 256
	ld \1, (\2) << 8 | (\3)
ENDM

NB_STREAMED_SPRITES equ 4

INCLUDE "res/console_tiles.vert.2bpp.size"
NB_CONSOLE_TILES equ SIZE / 16
INCLUDE "res/light_tiles.vert.2bpp.size"
NB_LIGHT_TILES equ SIZE / 16
INCLUDE "res/font.vert.2bpp.size"
NB_FONT_TILES equ SIZE / 16
INCLUDE "res/draft.uniq.2bpp.size"
NB_BG_TILES equ SIZE / 16

SECTION "Tiles", VRAM[$8000]
	ds 2 * 16 ; Blank tiles
vStreamedSpriteTiles:
	ds 16 * 2 * NB_STREAMED_SPRITES
vSpriteTiles:
	ds NB_CONSOLE_TILES * 16
.light
	ds NB_LIGHT_TILES * 16
vFontTiles:
	ds NB_FONT_TILES * 16
	assert @ <= $9000, "Can't access font from OAM! ({@} > $9000)"
vBGTiles:
	ds NB_BG_TILES * 16
	assert @ <= $9800, "Too many tiles! ({@} > $9800)"

BASE_TILE equ LOW(vBGTiles / 16)
LIGHT_BASE equ LOW(vSpriteTiles.light / 16)
assert LIGHT_BASE == BASE_LIGHT_TILE, "Light base predicted = {BASE_LIGHT_TILE}, real = {LIGHT_BASE}"
FONT_BASE equ LOW(vFontTiles / 16)
assert FONT_BASE == FONT_BASE_TILE, "Font base predicted = {FONT_BASE_TILE}, real = {FONT_BASE} (remember to update charmap, maybe?)"


SECTION "Entry point", ROM0[Q_EntryPoint]

EntryPoint: ; Only jump here during actual boot-up!!
	; `call Q_Memcpy` will write to $5C7F + $5C7E, but these'll get ignored
	; This will abort the init process, jumping into our patch
	ld sp, Retpoline + 2

	cp BOOTUP_A_CGB
	ld a, 0
	jr nz, .notColor
	rr b
	adc a, 2
.notColor
	ldh [Q_hConsoleType], a

	ld hl, Q_OAMDMA
	ld de, Q_hOAMDMA
	ld bc, 8
	call Q_Memcpy
Init: ; Jump here to re-perform initialization
	sub a
	ld bc, $1FFE
	ld hl, $C000
	call Q_Memset
	sub a
	ld bc, $3E
	ld hl, $FFC0
	call Q_Memset
	ld a, $C0
	call Q_hOAMDMA
	jp Q_Init


SECTION "Patch", ROM0[$5C7C]

Retpoline:
	dw Intro


Intro:
	ld sp, $E000

	; Init interrupts
	ld hl, StatHandler
	lb bc, hStatHandler.end - hStatHandler, LOW(hStatHandler)
	call CopyHRAM
	; ld hl, IntTrampolines
	lb bc, IntTrampolinesEnd - IntTrampolines, LOW(Q_hSTATTrampoline)
	call CopyHRAM

	ld a, IEF_VBLANK | IEF_LCDC
	ldh [rIE], a
	xor a
	ldh [rIF], a
	ei
	ldh [Q_hVBlankFlag], a

	; Turn LCD off for gfx init
	rst Q_WaitVBlank
	xor a
	ldh [rLCDC], a

	ldh a, [Q_hConsoleType]
	and a
	jr nz, .notSGB
	call Q_DetectSGB
	; DO NOT SET CONSOLE TYPE TO SGB
	; The game only performs SGB detection **and init** only if DMG is initially detected!!
	ldh [hIsSGB], a
	jr z, .notSGB
	; TODO: perform SGB init, including border transfer
	; Also, disable changing the border! (ICON_EN)
	; Don't forget to turn the LCD off again!
.notSGB

	;; VRAM init
	; Performed after SGB check because of the VRAM transfers

	; Copy secondary tilemap
	ld hl, Tilemap
	ld de, $9DCC
	ld bc, SecondaryMapCopySpecs
.writeSecondaryMapRow
	ld a, [bc] ; Read count
	inc bc
.copyPrelude
	ldh [hPreludeCopyCnt], a
	ld a, [hli]
	ld [de], a
	inc e ; inc de
	ldh a, [hPreludeCopyCnt]
	add a, $10
	jr nc, .copyPrelude
.copyTrailing
	ldh [hPreludeCopyCnt], a
	ld a, [hli] ; Advance read ptr
	ld a, [bc] ; Read tile
	inc bc
	ld [de], a
	inc e ; inc de
	; Only reason that this jump works is that the stars align. Don't try at home, kids
	jr z, .secondaryMapDone
	ldh a, [hPreludeCopyCnt]
	dec a
	jr nz, .copyTrailing
	ld a, BASE_TILE
.writeTrailing
	inc hl
	ld [de], a
	inc de
	bit 4, e
	jr nz, .writeTrailing
	ld a, e
	or $0C
	ld e, a
	jr .writeSecondaryMapRow
.secondaryMapDone
	; Just copy the rest
	ld de, $9F0C
	lb bc, 20, 8
	ld a, 32 - 20
	call Q_CopyRows

	ld hl, $9C00
	ld a, BASE_TILE + 1
	ld bc, 10 * SCRN_VX_B
	call Q_Memset
	dec a ; ld a, $80
	ld hl, $9800
	ld bc, 10 * SCRN_VX_B
	call Q_Memset
	xor a
	ld hl, $8000
	lb bc, vSpriteTiles - $8000, 0
	call Q_MemsetWithIncr
	; ld de, vSpriteTiles
	ld d, h
	ld e, l
	ld hl, Palettes
	ld c, LOW(rBCPS)
	call Q_CommitPalettes_writePalettes
	; Boot ROM only writes 1 byte to OCPD after writing $80 to OCPS
	lb bc, 1, LOW(rOCPD)
	call Q_CommitPalettes_writePalette
	; ld hl, Tiles
	call Q_RNCUnpack
	; ld hl, Tilemap
	ld de, $99CC
	lb bc, 20, 18
	ld a, 32 - 20
	call Q_CopyRows

	; Write LCD params & turn it on
	ld a, $E4
	ldh [rBGP], a
	xor a
	ldh [rOBP0], a
	ldh [rWY], a
	ld a, SCRN_X + 7
	ldh [rWX], a
	ld a, SCRN_VX - SCRN_X
	ldh [rSCX], a
	ld a, SCRN_VY - SCRN_Y
	ldh [rSCY], a
	ld a, STATF_LYC
	ldh [rSTAT], a
	ld a, OAM_SWAP_SCANLINE
	ldh [rLYC], a
	ld a, LCDCF_ON | LCDCF_WINON | LCDCF_OBJ16 | LCDCF_OBJ16 | LCDCF_OBJON | LCDCF_BGON
	ldh [rLCDC], a
	; Perform some additional setup work during the first (white) frame

	; Write sprites
	; ld hl, SpritePos
	lb bc, (SpritePos.end - SpritePos.light) / 2, SpritePos.light - SpritePos
	ld de, wLightOAM.end
	; Store text read ptr
	assert wLightOAM.end == wText
	push de
.writeConsoleSprite
	dec e ; dec de
	xor a
	ld [de], a
	dec e ; dec de
	ld a, c
	ld [de], a
	dec e ; dec de
	ld a, [hli]
	ld [de], a
	dec e ; dec de
	ld a, [hli]
	ld [de], a
	dec c
	dec c
	jr nz, .writeConsoleSprite
	; Write light sprite positions
.writeLightSprite
	dec e ; dec de
	xor a
	ld [de], a
	dec e ; dec de
	ld [de], a
	dec e ; dec de
	ld a, [hli]
	ld [de], a
	dec e ; dec de
	ld a, [hli]
	ld [de], a
	dec b
	jr nz, .writeLightSprite
	; Clear the remaining sprites
	xor a
.clearOAM
	dec e ; dec de
	ld [de], a
	jr nz, .clearOAM

	; ld hl, Data
	ld de, wData
	call Q_RNCUnpack
	; Decode that RLE
	; ld hl, wWindowXValues ↓
	ld h, d
	ld l, e
	ld de, wWindowXValuesRLE
.unpackWX
	ld a, [de]
	inc de
	srl a
	ld b, a
	jr z, .done
	jr c, .copy
	ld a, [de]
	inc de
.unRLE
	ld [hli], a
	dec b
	jr nz, .unRLE
	jr .unpackWX
.copy
	ld a, [de]
	inc de
	ld [hli], a
	dec b
	jr nz, .copy
	jr .unpackWX
.done

	; Init text OAM
	ld hl, wTextOAM.end - 1
	ld c, 38
.initTextOAM
	xor a
	ld [hld], a ; Attribute is constant
	ld [hld], a ; Will be overwritten
	ld [hld], a ; Hide them at the beginning
	ld a, LINE1_Y + 16 ; Y position is constant
	ld [hld], a
	dec c
	jr nz, .initTextOAM
	xor a
.clearTextOAM
	ld [hld], a
	bit 6, h
	jr nz, .clearTextOAM

	; Init vars
	; xor a
	ldh [Q_hCurKeys], a
	ld a, START_CNT
	ldh [hFrameCounter], a
    ld hl, CompressedMusicData
    ld de, wPatternData
    call Q_RNCUnpack
	call Q_Player_Initialize
	xor a
	call Q_Player_MusicStart
	; Check whether the `.noStep` jump will be taken or not... it shouldn't be.
	assert (START_CNT + 1) & 7 != 0, "Animation start ptr will not be loaded!"
	ld de, wWindowXValues + START_OFS


	; ACTUAL FX CODE GOES HERE
MainLoop:
	rst Q_WaitVBlank

	ld a, HIGH(wTextOAM)
	call Q_hOAMDMA

	; On DMG, blink the Game Boy to make it gray-ish
	; The Game Boy is hidden by the border on SGB, so that's fine
	ldh a, [rOBP0]
	xor $04
	ldh [rOBP0], a

	ldh a, [hFrameCounter]
	inc a
	ldh [hFrameCounter], a
	ld b, a

	; Every 8 frames, step the animation by advancing the reload point
	and 7
	jr nz, .noStep
	; Copy tiles using popslide (faster), since we know we won't be interrupted
	ld a, [hli]
	push hl
	ld h, [hl]
	ld l, a
	ld sp, hl
	ld hl, vStreamedSpriteTiles
	; Partial unrolling is necessary to perform WXzardry in time
	; 16 * 2 tiles per sprite, but 4 bytes copied per iteration
	ld c, 16 * 2 * NB_STREAMED_SPRITES / 4
.streamTile
	pop de
	ld a, e
	ld [hli], a
	ld [hli], a
	ld a, d
	ld [hli], a
	ld [hli], a
	dec c
	jr nz, .streamTile
	; Restore SP and HL, and keep truckin
	ld sp, $DFFC
	pop hl
	inc hl ; Skip high byte of ptr
	; Read sprite tiles
	ld a, [hli] ; Read sentinel byte
	add a, a
	ld c, a
	ld de, wLightOAM.light
.writeLightSpriteTile
	inc e ; inc de
	inc e ; inc de
	ld a, 0
	jr nc, .clearLightSpriteTile
	ld a, [hli]
.clearLightSpriteTile
	ld [de], a
	inc e ; inc de
	inc e ; inc de
	sla c
	jr nz, .writeLightSpriteTile
	ld d, h
	ld e, l
.noStep

	ld h, d
	ld l, e
	; Now, perform WXzardry, changing WX on each scanline
	; Stop when the window has been hidden
	; This will get interrupted by the OAM DMA, but this is made to be lenient,
	; at worst a couple scanlines will get duplicated.
.waitNotVBlank
	ldh a, [rLY]
	cp SCRN_Y
	jr nc, .waitNotVBlank
	ld c, 0
.stepWindow
	ldh a, [rLY]
	cp c
	jr c, .stepWindow
	ld a, [hli]
	ldh [rWX], a
	inc c
	sub SCRN_X + 7
	jr nz, .stepWindow

	; Check if end of animation will be reached; if so, re-swap tilemaps
	; (Safe to do so because we're below the window, anyway)
	ld a, b
	cp START_CNT - 1
	jr z, .swapTilemaps
	; Check if counter is about to reach 0, in which case, cycle the animation
	inc a
	jr nz, .noReset

	; Update text
	pop de ; Get back text ptr
	; We may write up to 2 sprites too many, but we made room for that
	ld hl, wTextOAM + (NB_TEXT_SPRITES + 2) * 4
	ld a, [de] ; Read X pos
	inc de
.readFirstLine
	add a, 8
	ld c, a
	dec l ; dec hl ; Y → Attr
	dec l ; dec hl ; Attr → Tile
	ld a, [de] ; Read char
	inc de
	ld [hld], a ; Tile → X
	dec a
	ld a, c
	ld [hld], a ; X → Y
	jr nz, .readFirstLine
	; Clear remaining sprites
	xor a
.clearFirstLine
	dec l ; dec hl ; Y → Attr
	dec l ; dec hl ; Attr → Tile
	ld [hld], a ; Tile → X
	dec l ; dec hl ; X → Y
	jr nz, .clearFirstLine
	; This loop may write 1 sprite too much, but the pointer is moved back afterwards
	ld hl, wLightOAM.light
	ld a, [de] ; Read X pos
	inc de
	ld c, a
.read2ndAgain
	ld a, c
.readSecondLine
	add a, 8
	ld c, a
	ld a, [de]
	inc de
	and a ; If it's a space, don't use a sprite for it
	jr z, .read2ndAgain
	dec l ; dec hl ; Y → Attr
	dec l ; dec hl ; Attr → Tile
	ld [hld], a ; Tile → X
	dec a
	ld a, c
	ld [hld], a ; X → Y
	ld [hl], LINE2_Y + 16
	jr nz, .readSecondLine
	inc l ; inc hl ; Y → X
	inc l ; inc hl ; X → Tile
	; This loop may write 1 sprite too much, but it'll write in the RLE buffer which contains stale data
	ld a, [de] ; Read X pos
	ld c, a
	inc de
	db $CA ; jp z, xxxx
.readThirdLine
	dec hl ; Y → Attr
	dec l ; dec hl ; Attr → Tile
.readAgain
	ld a, c
	add a, 8
	ld c, a
	ld a, [de]
	inc de
	and a ; If it's a space, don't use a sprite for it
	jr z, .readAgain
	ld [hld], a ; Tile → X
	dec a
	ld a, c
	ld [hld], a ; X → Y
	ld [hl], LINE3_Y + 16
	jr nz, .readThirdLine
	; The last sprite written by the above must not be shown, so start with that one
	xor a
.clear2nd3rdSprites
	ld [hld], a ; Y → Attr
	dec l ; dec hl ; Attr → Tile
	dec l ; dec hl ; Tile → X
	dec l ; dec hl ; X → Y
	bit 7, l
	jr z, .clear2nd3rdSprites
	; If next length is $00, start from beginning
	ld a, [de]
	and a
	jr nz, .noTextLoop
	ld de, wText
.noTextLoop
	push de ; Save for next iteration

	; Reload animation ptr
	ld hl, wWindowXValues
	; Swap tilemap behind window for 2nd part of animation
.swapTilemaps
	ldh a, [rLCDC]
	xor LCDCF_WIN9C00 | LCDCF_BG9C00
	ldh [rLCDC], a
.noReset

	push hl
	push de
	call Player_MusicUpdate
	pop de
	pop hl

	call Q_PollKeys
	jp z, MainLoop


	; TODO: on SGB, clear ICON_EN
	pop hl

	; The ROM relies on a lot of power-on state
	di
	call Q_Player_MusicStop
	call Q_ClearVRAM ; Also turns LCD off and returns with A = 0
	ldh [rSCX], a
	ldh [rSCY], a
	ldh [rIE], a
	ldh [Q_hPractice], a ; This also needs to be reset
	jp Init


CopyHRAM:
	ld a, [hli]
	ldh [c], a
	inc c
	dec b
	jr nz, CopyHRAM
	ret


Palettes:
INCBIN "res/palettes.bin"
Tiles:
INCBIN "res/tiles.2bpp.rnc"
; Expected to be contiguous
Tilemap:
INCBIN "res/draft.uniq.{x:BASE_TILE}.ofs.tilemap", 20
; Expected to be contiguous
SpritePos: ; (X, Y), reversed from OAM order!
	db 111 + 8,  72 + 16
	db 103 + 8,  73 + 16
	db  95 + 8,  75 + 16
	db  88 + 8,  78 + 16
	db  88 + 8,  94 + 16
	db 115 + 8,  86 + 16
	db 107 + 8,  91 + 16
	db 101 + 8,  95 + 16
	db  96 + 8,  96 + 16
	db 115 + 8, 102 + 16
	db 107 + 8, 107 + 16
	db 100 + 8, 111 + 16
	db  94 + 8, 110 + 16
	db 114 + 8, 118 + 16
	db 107 + 8, 118 + 16
	db 103 + 8, 127 + 16
NB_CONSOLE_SPRITES equ (@ - SpritePos) / 2
	; Console
	; These four are actually light sprites, but they use streamed tiles
	db 114 + 8,  76 + 16
	db 111 + 8,  72 + 16
	db 103 + 8,  72 + 16
	db 100 + 8,  75 + 16
	assert NB_STREAMED_SPRITES == (@ - SpritePos) / 2 - NB_CONSOLE_SPRITES
.light
	; Player
	db  70 + 8,  37 + 16
	db  74 + 8,  38 + 16
	db  79 + 8,  50 + 16
	db  75 + 8,  54 + 16
	db  79 + 8,  66 + 16
	db  75 + 8,  76 + 16
NB_LIGHT_SPRITES equ (@ - SpritePos) / 2 - NB_CONSOLE_SPRITES
.end
; Expected to be contiguous
Data:
INCBIN "res/data.bin.rnc"

; Count is formatted as such:
; - High nibble is (16 - initial_copy_len)
; - Low nibble is amount of tile IDs after it to copy
spec: macro
	db \1
	REPT _NARG - 1
		SHIFT
		db LOW(BASE_TILE + (\1))
	ENDR
endm
SecondaryMapCopySpecs:
	spec $81, $02
	spec $81, $03
	spec $81, $04
	spec $81, $04
	spec $82, $05, $06
	spec $71, $07
	spec $61, $08
	spec $62, $09, $0A
	spec $44, $0B, $0C, $0D, $0E
	spec $15, $0B, $0F, $10, $11, $12

StatHandler:
	LOAD "STAT handler", HRAM[$FF80]
hStatHandler:
	ld a, HIGH(wLightOAM)
	ldh [rDMA], a
	ld a, 40
.wait
	dec a
	jr nz, .wait
	pop af
	reti
.end
	ENDL

IntTrampolines:
	LOAD "Int trampolines", HRAM[Q_hSTATTrampoline]
	push af
	jr hStatHandler

assert @ == Q_hVBlankTrampoline
	jp Q_DefaultVBlankHandler
	ENDL
IntTrampolinesEnd:


Player_MusicUpdate:
    xor a
    ld hl, Q_hCarillonFFDC
    ld [hli], a
    ld a, [hli]
    call Q_Player_MusicUpdateFreqSlide
    call Q_Player_MusicUpdateCH1
    call Q_Player_MusicUpdateCH2
    call Q_Player_MusicUpdateCH3
    call Q_Player_MusicUpdateCH4
    ld hl, Q_hIsMusStopped
    ld a, [hli]
    or a
    ret nz

    ld a, [hli]
    dec [hl]
    jr z, jr_000_4422

    sra a
    cp [hl]
    ret nz

    jr jr_000_4423

jr_000_4422:
    ld [hl], a

jr_000_4423:
    inc l
    xor a
    or [hl]
    jr nz, jr_000_4444

    inc l
    inc l
    inc [hl]
    ld e, [hl]
    ld d, HIGH(wPatternTable)
    assert LOW(wPatternTable) == 0

jr_000_442e:
    ld a, [de]
    or a
    jr nz, jr_000_4442

    inc e
    ld a, [de]
    cpl
    or a
    jr nz, jr_000_443d

    inc a
    ld [Q_hIsMusStopped], a
    ret


jr_000_443d:
    cpl
    ld [hl], a
    ld e, a
    jr jr_000_442e

jr_000_4442:
    dec l
    ld [hld], a

jr_000_4444:
    ld d, $FF ; HIGH(<Carillon data>)
    ld a, [hli]
    ld h, [hl]
    ld l, a
    ld a, [hli]
    or a
    jr z, jr_000_4465

    ld e, $c9
    bit 0, a
    jr z, jr_000_4458

    and $fe
    ld [de], a
    jr jr_000_4465

jr_000_4458:
    ld [de], a
    ld a, [hl]
    dec e
    ld [de], a
    dec e
    ld a, $01
    ld [de], a
    dec e
    ld a, [de]
    and $fe
    ld [de], a

jr_000_4465:
    inc l
    ld a, [hli]
    or a
    jr z, jr_000_4482

    ld e, $cf
    bit 0, a
    jr z, jr_000_4475

    and $fe
    ld [de], a
    jr jr_000_4482

jr_000_4475:
    ld [de], a
    ld a, [hl]
    dec e
    ld [de], a
    dec e
    ld a, $01
    ld [de], a
    dec e
    ld a, [de]
    and $fe
    ld [de], a

jr_000_4482:
    inc l
    ld a, [hli]
    or a
    jr z, jr_000_44aa

    cp $ff
    jr z, jr_000_44d9

    ld e, $d6
    bit 0, a
    jr z, jr_000_4496

    and $fe
    ld [de], a
    jr jr_000_44aa

jr_000_4496:
    ld [de], a
    ld a, [hl]
    dec e
    ld [de], a
    dec e
    ld a, $fe
    ld [de], a
    dec e
    cpl
    ld [de], a
    xor a
    ld [Q_hMusSamCount], a
    dec e
    ld a, [de]
    and $fa
    ld [de], a

jr_000_44aa:
    inc l
    ld a, [hli]
    or a
    jr z, jr_000_44bd

    and $fe
    ld e, $db
    ld [de], a
    dec e
    ld a, $01
    ld [de], a
    dec e
    ld a, [de]
    and $fe
    ld [de], a

jr_000_44bd:
    ld a, [hli]
    ld b, a
    ld e, $c3
    ld a, l
    ld [de], a
    ld a, b
    or a
    jr z, jr_000_44d5

    swap a
    and $0f
    add a
    add $e0
    ld h, $46
    ld l, a
    ld a, [hli]
    ld h, [hl]
    ld l, a
    jp hl


jr_000_44d5:
    ld [Q_hMusModulate], a
    ret


jr_000_44d9:
    ld e, $e7
    ld a, $05
    ld [de], a
    ld a, [hl]
    add $f0
    ld c, a
    ld b, $47
    ld a, [bc]
    add a
    add a
    inc e
    ld [de], a
    ld a, [hl]
    add a
    add $c0
    ld b, $46
    ld c, a
    inc e
    xor a
    ld [de], a
    inc e
    ld a, [bc]
    ld [de], a
    inc c
    inc e
    ld a, [bc]
    ld [de], a
    jr jr_000_44aa

CompressedMusicData:
INCBIN "res/mus_data.bin.rnc"


SPACE_LEFT equ $8000 - @
	PRINTT "SPACE LEFT: {d:SPACE_LEFT} bytes\n"



SECTION "Text shadow OAM", WRAM0[$C000]

wTextOAM:
	ds 40 * 4
.end


SECTION "Shadow OAM", WRAM0[$C0FC]
; The byte at $C1FC may be overwritten with $00 by the text updating code, so reserve some space
	ds 4

EXPECTED = 40 - NB_LIGHT_SPRITES - NB_CONSOLE_SPRITES
static_assert NB_TEXT_SPRITES_2 == EXPECTED, "{NB_TEXT_SPRITES_2} != {EXPECTED}"

wLightOAM:
	ds NB_TEXT_SPRITES_2 * 4
.light
	ds NB_LIGHT_SPRITES * 4
.console
	ds NB_CONSOLE_SPRITES * 4
.end

wData:
wText:
INCLUDE "res/text.bin.size"
	ds SIZE

wWindowXValuesRLE:
INCLUDE "res/winx.bin.size"
	ds SIZE - NB_STREAMED_TILES * 16
.end
	static_assert @ == STREAMED_TILES_BASE, "Streamed tiles address mismatch! Predicted {STREAMED_TILES_BASE}, real {@}"
wWindowXValuesTiles:
	ds NB_STREAMED_TILES * 16
wWindowXValues:
	ds WXVAL_LEN
.end::


INCLUDE "res/mus_data.inc"
	static_assert wPulseInstrPanningTable == Q_wPulseInstrPanningTable, "{wPulseInstrPanningTable} != {Q_wPulseInstrPanningTable}"

SECTION "Music data", WRAM0[wPatternData]

INCLUDE "res/mus_data.bin.size"
	ds SIZE



SECTION "HRAM", HRAM[$FF91]

hIsSGB:
	db
hPreludeCopyCnt:
hFrameCounter:
	db

SECTION "OAM DMA", HRAM[Q_hOAMDMA - 2]

	ds 8 ; Original OAM DMA

SECTION "VBlank flag", HRAM[Q_hVBlankFlag]

	db
