-- -----------------------------------------------------------------------
--
--                                 FPGA 64
--
--     A fully functional commodore 64 implementation in a single FPGA
--
-- -----------------------------------------------------------------------
-- Peter Wendrich (pwsoft@syntiac.com)
-- http://www.syntiac.com/fpga64.html
-- -----------------------------------------------------------------------
--
-- VIC-II - Video Interface Chip no 2
--
-- -----------------------------------------------------------------------
-- Dar 08/03/2014 : shift hsync to sprite #3
-- -----------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;

entity video_vicii_656x is
	generic (
		registeredAddress : boolean;
		emulateRefresh : boolean := false;
		emulateLightpen : boolean := false;
		emulateGraphics : boolean := true
	);
	port (
		clk: in std_logic;
		-- phi = 0 is VIC cycle
		-- phi = 1 is CPU cycle (only used by VIC when BA is low)
		phi : in std_logic;
		enaData : in std_logic;
		enaPixel : in std_logic;

		baSync : in std_logic;
		ba: out std_logic;

		mode6569 : in std_logic; -- PAL 63 cycles and 312 lines
		mode6567old : in std_logic; -- old NTSC 64 cycles and 262 line
		mode6567R8 : in std_logic; -- new NTSC 65 cycles and 263 line
		mode6572 : in std_logic; -- PAL-N 65 cycles and 312 lines

		reset : in std_logic;
		cs : in std_logic;
		we : in std_logic;
		rd : in std_logic;
		lp_n : in std_logic;

		aRegisters: in unsigned(5 downto 0);
		diRegisters: in unsigned(7 downto 0);

		di: in unsigned(7 downto 0);
		diColor: in unsigned(3 downto 0);
		do: out unsigned(7 downto 0);

		vicAddr: out unsigned(13 downto 0);
		irq_n: out std_logic;

		-- Video output
		hSync : out std_logic;
		vSync : out std_logic;
		colorIndex : out unsigned(3 downto 0);

		-- Debug outputs
		debugX : out unsigned(9 downto 0);
		debugY : out unsigned(8 downto 0);
		vicRefresh : out std_logic;
		addrValid : out std_logic
	);
end entity;

architecture rtl of video_vicii_656x is
	type vicCycles is (
		cycleRefresh1, cycleRefresh2, cycleRefresh3, cycleRefresh4, cycleRefresh5,
		cycleIdle1,
		cycleChar,
		cycleCalcSprites, cycleSpriteBa1, cycleSpriteBa2, cycleSpriteBa3,
		cycleSpriteA, cycleSpriteB
	);
	subtype ColorDef is unsigned(3 downto 0);
	type MFlags is array(0 to 7) of boolean;
	type MXdef is array(0 to 7) of unsigned(8 downto 0);
	type MYdef is array(0 to 7) of unsigned(7 downto 0);
	type MCntDef is array(0 to 7) of unsigned(5 downto 0);
	type MPixelsDef is array(0 to 7) of unsigned(23 downto 0);
	type MCurrentPixelDef is array(0 to 7) of unsigned(1 downto 0);
	type charStoreDef is array(38 downto 0) of unsigned(11 downto 0);
	type spriteColorsDef is array(7 downto 0) of unsigned(3 downto 0);
	type pixelColorStoreDef is array(7 downto 0) of unsigned(3 downto 0);

-- State machine
	signal lastLineFlag : boolean; -- True for on last line of the frame.
	signal beyondFrameFlag : boolean; -- Y>frame lines
	signal vicCycle : vicCycles := cycleRefresh1;
	signal sprite : unsigned(2 downto 0) := "000";
	signal shiftChars : boolean;
	signal idle: std_logic := '1';
	signal rasterIrqDone : std_logic; -- Only one interrupt each rasterLine
	signal rasterEnable: std_logic;

-- BA signal
	signal badLine : boolean; -- true if we have a badline condition
	signal baLoc : std_logic;
	signal baCnt : unsigned(2 downto 0);

	signal baChars : std_logic;
	signal baSprite04 : std_logic;
	signal baSprite15 : std_logic;
	signal baSprite26 : std_logic;
	signal baSprite37 : std_logic;

-- Memory refresh cycles
	signal refreshCounter : unsigned(7 downto 0);

-- User registers
	signal MX : MXdef; -- Sprite X
	signal MY : MYdef; -- Sprite Y
	signal ME : unsigned(7 downto 0); -- Sprite enable
	signal MXE : unsigned(7 downto 0); -- Sprite X expansion
	signal MYE : unsigned(7 downto 0); -- Sprite Y expansion
	signal MPRIO : unsigned(7 downto 0); -- Sprite priority
	signal MC : unsigned(7 downto 0); -- sprite multi color

	-- !!! Krestage 3 hacks
	signal MCDelay : unsigned(7 downto 0); -- sprite multi color

	-- mode
	signal BMM: std_logic; -- Bitmap mode
	signal ECM: std_logic; -- Extended color mode
	signal MCM: std_logic; -- Multi color mode
	signal DEN: std_logic; -- DMA enable
	signal RSEL: std_logic; -- Visible rows selection (24/25)
	signal CSEL: std_logic; -- Visible columns selection (38/40)

	signal RES: std_logic;

	signal VM: unsigned(13 downto 10);
	signal CB: unsigned(13 downto 11);

	signal EC : ColorDef;  -- border color
	signal B0C : ColorDef; -- background color 0
	signal B1C : ColorDef; -- background color 1
	signal B2C : ColorDef; -- background color 2
	signal B3C : ColorDef; -- background color 3
	signal MM0 : ColorDef; -- sprite multicolor 0
	signal MM1 : ColorDef; -- sprite multicolor 1
	signal spriteColors: spriteColorsDef;

-- borders and blanking
	signal LRBorder: std_logic;
	signal TBBorder: std_logic;
	signal hBlack: std_logic;
	signal vBlanking : std_logic;
	signal hBlanking : std_logic;
	signal xscroll: unsigned(2 downto 0);
	signal yscroll: unsigned(2 downto 0);
	signal rasterCmp : unsigned(8 downto 0);

-- Address generator
	signal vicAddrReg : unsigned(13 downto 0);
	signal vicAddrLoc : unsigned(13 downto 0);

-- Address counters
	signal ColCounter: unsigned(9 downto 0) := (others => '0');
	signal ColRestart: unsigned(9 downto 0) := (others => '0');
	signal RowCounter: unsigned(2 downto 0) := (others => '0');

-- IRQ Registers
	signal IRST: std_logic := '0';
	signal ERST: std_logic := '0';
	signal IMBC: std_logic := '0';
	signal EMBC: std_logic := '0';
	signal IMMC: std_logic := '0';
	signal EMMC: std_logic := '0';
	signal ILP: std_logic := '0';
	signal ELP: std_logic := '0';
	signal IRQ: std_logic;

-- Collision detection registers
	signal M2M: unsigned(7 downto 0); -- Sprite to sprite collision
	signal M2D: unsigned(7 downto 0); -- Sprite to character collision
	signal M2Mhit : std_logic;
	signal M2Dhit : std_logic;

-- Raster counters
	signal rasterX : unsigned(9 downto 0) := (others => '0');
	signal rasterY : unsigned(8 downto 0) := (others => '0');

-- Light pen
	signal lightPenHit: std_logic;
	signal lpX : unsigned(7 downto 0);
	signal lpY : unsigned(7 downto 0);

-- IRQ Resets
	signal resetLightPenIrq: std_logic;
	signal resetIMMC : std_logic;
	signal resetIMBC : std_logic;
	signal resetRasterIrq : std_logic;

-- Character generation
	signal charStore: charStoreDef;
	signal nextChar : unsigned(11 downto 0);
	-- Char/Pixels just coming from memory
	signal readChar : unsigned(11 downto 0);
	signal readPixels : unsigned(7 downto 0);
	-- Char/Pixels pair waiting to be shifted
	signal waitingChar : unsigned(11 downto 0);
	signal waitingPixels : unsigned(7 downto 0);
	-- Stores colorinfo and the Pixels that are currently in shift register
	signal shiftingChar : unsigned(11 downto 0);
	signal shiftingPixels : unsigned(7 downto 0);
	signal shifting_ff : std_logic; -- Multicolor shift-regiter status bit.

-- Sprite work registers
	signal MPtr : unsigned(7 downto 0); -- sprite base pointer
	signal MPixels : MPixelsDef; -- Sprite 24 bit shift register
	signal MActive : MFlags; -- Sprite is active (derived from MCnt)
	signal MCnt : MCntDef;
	signal MXE_ff : unsigned(7 downto 0); -- Sprite X expansion flipflop
	signal MYE_ff : unsigned(7 downto 0); -- Sprite Y expansion flipflop
	signal MC_ff : unsigned(7 downto 0); -- controls sprite shift-register in multicolor
	signal MShift : MFlags; -- Sprite is shifting
	signal MCurrentPixel : MCurrentPixelDef;

-- Current colors and pixels
	signal pixelColor: ColorDef;
	signal pixelBgFlag: std_logic; -- For collision detection
	signal pixelDelay: pixelColorStoreDef;

-- Read/Write lines
	signal myWr : std_logic;
	signal myRd : std_logic;

begin
-- -----------------------------------------------------------------------
-- Ouput signals
-- -----------------------------------------------------------------------
	ba <= baLoc;
	vicAddr <= vicAddrReg when registeredAddress else vicAddrLoc;
	hSync <= hBlanking;
	vSync <= vBlanking;
	irq_n <= not IRQ;

-- -----------------------------------------------------------------------
-- chip-select signals
-- -----------------------------------------------------------------------
	myWr <= cs and we;
	myRd <= cs and rd;

-- -----------------------------------------------------------------------
-- debug signals
-- -----------------------------------------------------------------------
	debugX <= rasterX;
	debugY <= rasterY;

-- -----------------------------------------------------------------------
-- Badline condition
-- -----------------------------------------------------------------------
	process(rasterY, yscroll, rasterEnable)
	begin
		badLine <= false;
		if (rasterY(2 downto 0) = yscroll)
		and (rasterEnable = '1') then
			badLine <= true;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- BA=low counter
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if baLoc = '0' then
				if phi = '0'
				and enaData = '1'
				and baCnt(2) = '0' then
					baCnt <= baCnt + 1;
				end if;
			else
				baCnt <= (others => '0');
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Calculate lastLineFlag
-- -----------------------------------------------------------------------
	process(clk)
		variable rasterLines : integer range 0 to 312;
	begin
		if rising_edge(clk) then
			lastLineFlag <= false;

			rasterLines := 311; -- PAL
			if mode6567old = '1' then
				rasterLines := 261; -- NTSC (R7 and earlier have 262 lines)
			end if;
			if mode6567R8 = '1' then
				rasterLines := 262; -- NTSC (R8 and newer have 263 lines)
			end if;
			if rasterY = rasterLines then
				lastLineFlag <= true;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- State machine
-- -----------------------------------------------------------------------
vicStateMachine: process(clk)
	begin
		if rising_edge(clk) then
			if enaData = '1'
			and baSync = '0' then
				if phi = '0' then
					case vicCycle is
					when cycleRefresh1 =>
						vicCycle <= cycleRefresh2;
						if ((mode6567old or mode6567R8) = '1') then
							vicCycle <= cycleIdle1;
						end if;
					when cycleIdle1 => vicCycle <= cycleRefresh2;
					when cycleRefresh2 => vicCycle <= cycleRefresh3;
					when cycleRefresh3 => vicCycle <= cycleRefresh4;
					when cycleRefresh4 => vicCycle <= cycleRefresh5;  -- X=0..7 on this cycle
					when cycleRefresh5 => vicCycle <= cycleChar;
					when cycleChar =>
						if ((mode6569  = '1') and rasterX(9 downto 3) = "0100111") -- PAL
						or ((mode6567old  = '1') and rasterX(9 downto 3) = "0100111") -- Old NTSC
						or ((mode6567R8  = '1') and rasterX(9 downto 3) = "0101000") -- New NTSC
						or ((mode6572  = '1') and rasterX(9 downto 3) = "0101000") then -- PAL-N
							vicCycle <= cycleCalcSprites;
						end if;
					when cycleCalcSprites => vicCycle <= cycleSpriteBa1;
					when cycleSpriteBa1 => vicCycle <= cycleSpriteBa2;
					when cycleSpriteBa2 => vicCycle <= cycleSpriteBa3;
					when others =>
						null;
					end case;
				else
					case vicCycle is
					when cycleSpriteBa3 => vicCycle <= cycleSpriteA;
					when cycleSpriteA =>
						vicCycle <= cycleSpriteB;
					when cycleSpriteB =>
						vicCycle <= cycleSpriteA;
						if sprite = 7 then
							vicCycle <= cycleRefresh1;
						end if;
					when others =>
						null;
					end case;
				end if;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Iterate through all sprites.
-- Only used when state-machine above is in any sprite cycles.
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if phi = '1'
			and enaData = '1'
			and vicCycle = cycleSpriteB
			and baSync = '0' then
				sprite <= sprite + 1;
			end if;
		end if;			
	end process;

-- -----------------------------------------------------------------------
-- Address generator
-- -----------------------------------------------------------------------
	process(phi, vicCycle, sprite, shiftChars, idle,
			VM, CB, ECM, BMM, nextChar, colCounter, rowCounter, MPtr, MCnt)
	begin
		--
		-- Default case ($3FFF fetches)
		vicAddrLoc <= (others => '1');
		if (idle = '0')
		and shiftChars then
			if BMM = '1' then
				vicAddrLoc <= CB(13) & colCounter & rowCounter;
			else
				vicAddrLoc <= CB & nextChar(7 downto 0) & rowCounter;
			end if;
		end if;
		if ECM = '1' then
			vicAddrLoc(10 downto 9) <= "00";
		end if;

		case vicCycle is
		when cycleRefresh1 | cycleRefresh2 | cycleRefresh3 | cycleRefresh4 | cycleRefresh5 =>
			if emulateRefresh then
				vicAddrLoc <= "111111" & refreshCounter;
			else
				vicAddrLoc <= (others => '-');
			end if;
		when cycleSpriteBa1 | cycleSpriteBa2 | cycleSpriteBa3 =>
			vicAddrLoc <= (others => '1');
		when cycleSpriteA =>
			vicAddrLoc <= VM & "1111111" & sprite;
			if phi = '1' then
				vicAddrLoc <= MPtr & MCnt(to_integer(sprite));
			end if;
		when cycleSpriteB =>
			vicAddrLoc <= MPtr & MCnt(to_integer(sprite));
		when others =>
			if phi = '1' then
				vicAddrLoc <= VM & colCounter;
			end if;
		end case;
	end process;
	
	-- Registered address
	process(clk)
	begin
		if rising_edge(clk) then
			vicAddrReg <= vicAddrLoc;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Character storage
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if enaData = '1'
			and shiftChars
			and phi = '1' then
				if badLine then
					nextChar(7 downto 0) <= di;
					nextChar(11 downto 8) <= diColor;
				else
					nextChar <= charStore(38);
				end if;
				charStore <= charStore(37 downto 0) & nextChar;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Sprite base pointer (MPtr)
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if phi = '0'
			and enaData = '1'
			and vicCycle = cycleSpriteA then
				MPtr <= (others => '1');
				if MActive(to_integer(sprite)) then
					MPtr <= di;
				end if;

				-- If refresh counter is not emulated we don't care about
				-- MPtr having the correct value in idle state.
				if not emulateRefresh then
					MPtr <= di;
				end if;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Refresh counter
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			vicRefresh <= '0';
			case vicCycle is
			when cycleRefresh1 | cycleRefresh2 | cycleRefresh3 | cycleRefresh4 | cycleRefresh5 =>
				vicRefresh <= '1';
				if phi = '0'
				and enaData = '1'
				and baSync = '0' then
					refreshCounter <= refreshCounter - 1;
				end if;
			when others =>
				null;
			end case;
			if lastLineFlag then
				refreshCounter <= (others => '1');
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Generate Raster Enable
-- -----------------------------------------------------------------------
	process(clk)
	begin
		-- Enable screen and character display.
		-- This is only possible in line 48 on the VIC-II.
		-- On other lines any DEN changes are ignored.
		if rising_edge(clk) then
			if (rasterY = 48) and (DEN = '1') then
				rasterEnable <= '1';
			end if;
			if (rasterY = 248) then
				rasterEnable <= '0';
			end if;
		end if;
	end process;


-- -----------------------------------------------------------------------
-- BA generator (Text/Bitmap)
-- -----------------------------------------------------------------------
--
-- For Text/Bitmap BA goes low 3 cycles before real access. So BA starts
-- going low during refresh2 state. See diagram below for timing:
--
-- X               0  0  0  0  0
--                 0  0  0  0  1
--                 0  4  8  C  0
--
-- phi ___   ___   ___   ___   ___   ___   ___   ___...
--        ___   ___   ___   ___   ___   ___   ___   ...
--
--          |     |     |     |     |     |     |...
--     rfr2  rfr3  rfr4  rfr5  char1 char2 char3
--
-- BA _______
--        \\\_______________________________________
--          |  1  |  2  |  3  |
--
-- BACnt 000  001 | 010 | 011 | 100   100   100  ...
--
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if phi = '0' then
				baChars <= '1';
				case vicCycle is
				when cycleRefresh2 | cycleRefresh3 | cycleRefresh4 | cycleRefresh5 =>
					if badLine then
						baChars <= '0';
					end if;
				when others =>
					if rasterX(9 downto 3) < "0101000"
					and badLine then
						baChars <= '0';
					end if;
				end case;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- BA generator (Sprites)
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if phi = '0' then
				if sprite = 1 then
					baSprite04 <= '1';
				end if;
				if sprite = 2 then
					baSprite15 <= '1';
				end if;
				if sprite = 3 then
					baSprite26 <= '1';
				end if;
				if sprite = 4 then
					baSprite37 <= '1';
				end if;
				if sprite = 5 then
					baSprite04 <= '1';
				end if;
				if sprite = 6 then
					baSprite15 <= '1';
				end if;
				if sprite = 7 then
					baSprite26 <= '1';
				end if;
				if vicCycle = cycleRefresh1 then
					baSprite37 <= '1';
				end if;
				
				if MActive(0) and (vicCycle = cycleCalcSprites) then
					baSprite04 <= '0';
				end if;
				if MActive(1) and (vicCycle = cycleSpriteBa2) then
					baSprite15 <= '0';
				end if;
				if MActive(2) and (vicCycle = cycleSpriteB) and (sprite = 0) then
					baSprite26 <= '0';
				end if;
				if MActive(3) and (vicCycle = cycleSpriteB) and (sprite = 1) then
					baSprite37 <= '0';
				end if;
				if MActive(4) and (vicCycle = cycleSpriteB) and (sprite = 2) then
					baSprite04 <= '0';
				end if;
				if MActive(5) and (vicCycle = cycleSpriteB) and (sprite = 3) then
					baSprite15 <= '0';
				end if;
				if MActive(6) and (vicCycle = cycleSpriteB) and (sprite = 4) then
					baSprite26 <= '0';
				end if;
				if MActive(7) and (vicCycle = cycleSpriteB) and (sprite = 5) then
					baSprite37 <= '0';
				end if;
			end if;
		end if;
	end process;
	baLoc <= baChars and baSprite04 and baSprite15 and baSprite26 and baSprite37;

-- -----------------------------------------------------------------------
-- Address valid?
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			addrValid <= '0';
			if phi = '0'
			or baCnt(2) = '1' then
				addrValid <= '1';
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Generate ShiftChars flag
-- -----------------------------------------------------------------------
	process(rasterX)
	begin
		shiftChars <= false;
		if rasterX(9 downto 3) > "0000000"
		and rasterX(9 downto 3) < "0101001" then
			shiftChars <= true;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- RowCounter and ColCounter
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if phi = '0'
			and enaData = '1'
			and baSync = '0' then
				if shiftChars
				and idle = '0' then
					colCounter <= colCounter + 1;
				end if;
				case vicCycle is
				when cycleRefresh4 =>
					colCounter <= colRestart;
					if badline then
						rowCounter <= (others => '0');
					end if;
				when cycleSpriteA =>
					if sprite = "000" then
						if rowCounter = 7 then
							colRestart <= colCounter;
							idle <= '1';
						else
							rowCounter <= rowCounter + 1;
						end if;
						if badline then
							rowCounter <= rowCounter + 1;
						end if;
					end if;
				when others =>
					null;					
				end case;
				if lastLineFlag then
					-- Reset column counter outside visible range.
					colRestart <= (others => '0');
				end if;

				-- Set display mode (leave idle-mode) as soon as
				-- there is a badline condition.
				if badline then
					idle <= '0';
				end if;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- X/Y Raster counter
-- -----------------------------------------------------------------------
rasterCounters: process(clk)
	begin
		if rising_edge(clk) then
			if enaPixel = '1' then
				rasterX(2 downto 0) <= rasterX(2 downto 0) + 1;
			end if;
			if phi = '0'
			and enaData = '1'
			and baSync = '0' then
				rasterX(9 downto 3) <= rasterX(9 downto 3) + 1;
				rasterX(2 downto 0) <= (others => '0');
				if vicCycle = cycleRefresh4 then
					rasterX <= (others => '0');
				end if;
			end if;
			if phi = '1'
			and enaData = '1'
			and baSync = '0' then
				beyondFrameFlag <= false;
				if (vicCycle = cycleSpriteB)
				and (sprite = 2) then
					rasterY <= rasterY + 1;
					beyondFrameFlag <= lastLineFlag;
				end if;
				if beyondFrameFlag then
					rasterY <= (others => '0');
				end if;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Raster IRQ
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if phi = '1'
			and enaData = '1'
			and baSync = '0'
			and (vicCycle = cycleSpriteB)
			and (sprite = 2) then
				rasterIrqDone <= '0';
			end if;
			if resetRasterIrq = '1' then
				IRST <= '0';
			end if;
			if (rasterIrqDone = '0')
			and (rasterY = rasterCmp) then
				rasterIrqDone <= '1';
				IRST <= '1';
			end if;
		end if;
	end process;


-- -----------------------------------------------------------------------
-- Light pen
-- -----------------------------------------------------------------------
-- On a negative edge on the LP input, the current position of the raster beam
-- is latched in the registers LPX ($d013) and LPY ($d014). LPX contains the
-- upper 8 bits (of 9) of the X position and LPY the lower 8 bits (likewise of
-- 9) of the Y position. So the horizontal resolution of the light pen is
-- limited to 2 pixels.

-- Only one negative edge on LP is recognized per frame. If multiple edges
-- occur on LP, all following ones are ignored. The trigger is not released
-- until the next vertical blanking interval.
-- -----------------------------------------------------------------------
lightPen: process(clk)
	begin
		if rising_edge(clk) then
			if emulateLightpen then
				if resetLightPenIrq = '1' then
					-- Reset light pen interrupt
					ILP <= '0';
				end if;			
				if lastLineFlag then
					-- Reset lightpen state at beginning of frame
					lightPenHit <= '0';
				elsif (lightPenHit = '0') and (lp_n = '0') then
					-- One hit/frame
					lightPenHit <= '1'; 
					-- Toggle Interrupt
					ILP <= '1'; 
					-- Store position of beam
					lpx <= rasterX(8 downto 1);
					lpy <= rasterY(7 downto 0);
				end if;
			else
				ILP <= '0';
				lpx <= (others => '1');
				lpy <= (others => '1');
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- VSync
-- -----------------------------------------------------------------------
doVBlanking: process(clk, mode6569, mode6567old, mode6567R8)
		variable rasterBlank : integer range 0 to 300;
	begin
		rasterBlank := 300;
		if (mode6567old or mode6567R8) = '1' then
			rasterBlank := 12;
		end if;
		if rising_edge(clk) then
			vBlanking <= '0';
			if rasterY = rasterBlank then
				vBlanking <= '1';
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- HSync
-- -----------------------------------------------------------------------
doHBlanking: process(clk)
	begin
		if rising_edge(clk) then
			if sprite = 3 then
				hBlack <= '1';
			end if;
			if vicCycle = cycleRefresh1 then
				hBlack <= '0';
			end if;
			if sprite = 3 then -- dar 5 then
				hBlanking <= '1';
			else
				hBlanking <= '0';
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Borders
-- -----------------------------------------------------------------------
calcBorders: process(clk)
		variable newTBBorder: std_logic;
	begin
		if rising_edge(clk) then
			if enaPixel = '1' then
				--
				-- Calc top/bottom border
				newTBBorder := TBBorder;
--				if (rasterY = 55) and (RSEL = '0') and (rasterEnable = '1') then
				if (rasterY = 55) and (rasterEnable = '1') then
					newTBBorder := '0';
				end if;
				if (rasterY = 51) and (RSEL = '1') and (rasterEnable = '1') then
					newTBBorder := '0';
				end if;
				if (rasterY = 247) and (RSEL = '0') then
					newTBBorder := '1';
				end if;
				if (rasterY = 251) and (RSEL = '1') then
					newTBBorder := '1';
				end if;

				--
				-- Calc left/right border
				if (rasterX = (31+1)) and (CSEL = '0') then
					LRBorder <= newTBBorder;
					TBBorder <= newTBBorder;
				end if;
				if (rasterX = (24+1)) and (CSEL = '1') then
					LRBorder <= newTBBorder;
					TBBorder <= newTBBorder;
				end if;
				if (rasterX = (335+1)) and (CSEL = '0') then
					LRBorder <= '1';
				end if;
				if (rasterX = (344+1)) and (CSEL = '1') then
					LRBorder <= '1';
				end if;
			end if;
		end if;
	end process;


-- -----------------------------------------------------------------------
-- Pixel generator for Text/Bitmap screen
-- -----------------------------------------------------------------------
calcBitmap: process(clk)
		variable multiColor : std_logic;
	begin
		if rising_edge(clk) then
			if enaPixel = '1' then
				--
				-- Toggle flipflop for multicolor 2-bits shift.
				shifting_ff <= not shifting_ff;
				
				--
				-- Multicolor mode is active with MCM, but for character
				-- mode it depends on bit3 of color ram too.
				multiColor := MCM and (BMM or ECM or shiftingChar(11));

				--
				-- Reload shift register when xscroll=rasterX
				-- otherwise shift pixels
				if xscroll = rasterX(2 downto 0) then
					shifting_ff <= '0';
					shiftingChar <= waitingChar;
					shiftingPixels <= waitingPixels;
				elsif multiColor = '0' then
					shiftingPixels <= shiftingPixels(6 downto 0) & '0';
				elsif shifting_ff = '1' then
					shiftingPixels <= shiftingPixels(5 downto 0) & "00";
				end if;

				--
				-- Calculate if pixel is in foreground or background
				pixelBgFlag <= shiftingPixels(7);

				--
				-- Calculate color of next pixel				
				pixelColor <= B0C;
				if (BMM = '0') and (ECM='0') then
					if (multiColor = '0') then
						-- normal character mode
						if shiftingPixels(7) = '1' then
							pixelColor <= shiftingChar(11 downto 8);
						end if;
					else
						-- multi-color character mode
						case shiftingPixels(7 downto 6) is
						when "01" => pixelColor <= B1C;
						when "10" => pixelColor <= B2C;
						when "11" => pixelColor <= '0' & shiftingChar(10 downto 8);
						when others => null;
						end case;
					end if;
				elsif (MCM = '0') and (BMM = '0') and (ECM='1') then
					-- extended-color character mode
					-- multiple background colors but only 64 characters
					if shiftingPixels(7) = '1' then
						pixelColor <= shiftingChar(11 downto 8);
					else
						case shiftingChar(7 downto 6) is
						when "01" => pixelColor <= B1C;
						when "10" => pixelColor <= B2C;
						when "11" => pixelColor <= B3C;
						when others	=> null;
						end case;
					end if;
				elsif emulateGraphics and (MCM = '0') and (BMM = '1') and (ECM='0') then
					-- highres bitmap mode
					if shiftingPixels(7) = '1' then
						pixelColor <= shiftingChar(7 downto 4);
					else
						pixelColor <= shiftingChar(3 downto 0);
					end if;
				elsif emulateGraphics and (MCM = '1') and (BMM = '1') and (ECM='0') then
					-- Multi-color bitmap mode
					case shiftingPixels(7 downto 6) is
					when "01" => pixelColor <= shiftingChar(7 downto 4);
					when "10" => pixelColor <= shiftingChar(3 downto 0);
					when "11" => pixelColor <= shiftingChar(11 downto 8);
					when others => null;
					end case;
				else
					-- illegal display mode, the output is black
					pixelColor <= "0000";
				end if;
			end if;

			--
			-- Store fetched pixels, until current pixels are displayed
			-- and shift-register is empty.
			if enaData = '1'
			and phi = '0' then
				readPixels <= (others => '0');
				if shiftChars then
					readPixels <= di;
					readChar <= (others => '0');
					if idle = '0' then
						readChar <= nextChar;
					end if;
				end if;
				-- Store the characters until shiftregister is empty
				waitingPixels <= readPixels;
				waitingChar <= readChar;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Which sprites are active?
-- -----------------------------------------------------------------------
	process(MCnt)
	begin
		for i in 0 to 7 loop
			MActive(i) <= false;
			if MCnt(i) /= 63 then
				MActive(i) <= true;
			end if;
		end loop;
	end process;

-- -----------------------------------------------------------------------
-- Sprite byte counter
-- Y expansion flipflop
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if phi = '0'
			and enaData = '1' then
				case vicCycle is
				when cycleRefresh5 =>
					for i in 0 to 7 loop
						MYE_ff(i) <= not MYE_ff(i);
						if MActive(i) then
							if MYE_ff(i) = MYE(i) then
								MCnt(i) <= MCnt(i) + 1;
							else
								MCnt(i) <= MCnt(i) - 2;
							end if;
						end if;
					end loop;
				when others =>
					null;
				end case;
			end if;
			for i in 0 to 7 loop
				if MYE(i) = '0'
				or not MActive(i) then
					MYE_ff(i) <= '0';
				end if;
			end loop;
			
			--
			-- On cycleCalcSprite check for each inactive sprite if
			-- there is a Y match. Reset MCnt if this is so.
			--
			-- The RasterX counter is used here to multiplex the compare logic.
			-- This saves a few logic cells in the FPGA.
			if vicCycle = cycleCalcSprites then
				if (not MActive(to_integer(RasterX(2 downto 0))))
				and (ME(to_integer(RasterX(2 downto 0))) = '1')
				and (rasterY(7 downto 0) = MY(to_integer(RasterX(2 downto 0)))) then
					MCnt(to_integer(RasterX(2 downto 0))) <= (others => '0');
				end if;
			end if;
			--
			-- Original non-multiplexed version
--				if vicCycle = cycleCalcSprites then
--					for i in 0 to 7 loop
--						if (not MActive(i))
--						and (ME(i) = '1')
--						and (rasterY(7 downto 0) = MY(i)) then
--							MCnt(i) <= (others => '0');
--						end if;
--					end loop;						
--				end if;
			
			--
			-- Increment MCnt after fetching data.
			if enaData = '1' then
				if (vicCycle = cycleSpriteA and phi = '1')
				or (vicCycle = cycleSpriteB and phi = '0') then
					if MActive(to_integer(sprite)) then
						MCnt(to_integer(sprite)) <= MCnt(to_integer(sprite)) + 1;
					end if;
				end if;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Sprite pixel Shift register
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if enaPixel = '1' then
				-- Enable sprites on the correct X position
				for i in 0 to 7 loop
					if rasterX = MX(i) then
						MShift(i) <= true;
					end if;
				end loop;

				-- Shift one pixel of the sprite from the shift register.
				for i in 0 to 7 loop
					if MShift(i) then
						MXE_ff(i) <= (not MXE_ff(i)) and MXE(i);
						if MXE_ff(i) = '0' then
							MC_ff(i) <= (not MC_ff(i)) and MC(i);
							if MC_ff(i) = '0' then
								MCurrentPixel(i) <= MPixels(i)(23 downto 22);
							end if;
							MPixels(i) <= MPixels(i)(22 downto 0) & '0';
						end if;
					else
						MXE_ff(i) <= '0';
						MC_ff(i) <= '0';
						MCurrentPixel(i) <= "00";
					end if;
				end loop;
			end if;

			--
			-- Fill Sprite shift-register with new data.
			if enaData = '1' then
				if phi = '0'
				and vicCycle = cycleSpriteA then
					MShift(to_integer(sprite)) <= false;
				end if;

				if Mactive(to_integer(sprite)) then
					if phi = '0' then
						case vicCycle is
						when cycleSpriteB =>
							MPixels(to_integer(sprite)) <= MPixels(to_integer(sprite))(15 downto 0) & di;
						when others => null;
						end case;
					else
						case vicCycle is
						when cycleSpriteA | cycleSpriteB =>
							MPixels(to_integer(sprite)) <= MPixels(to_integer(sprite))(15 downto 0) & di;
						when others => null;
						end case;
					end if;
				end if;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Video output
-- -----------------------------------------------------------------------
	process(clk)
		variable myColor: unsigned(3 downto 0);
		variable muxSprite : unsigned(2 downto 0);
		variable muxColor : unsigned(1 downto 0);
		-- 00 = pixels
		-- 01 = MM0
		-- 10 = Sprite
		-- 11 = MM1
	begin
		if rising_edge(clk) then
			muxColor := "00";
			muxSprite := (others => '-');
			for i in 7 downto 0 loop
				if (MPRIO(i) = '0') or (pixelBgFlag = '0') then
					if MC(i) = '1' then
						if MCurrentPixel(i) /= "00" then
							muxColor := MCurrentPixel(i);
							muxSprite := to_unsigned(i, 3);
						end if;
					elsif MCurrentPixel(i)(1) = '1' then
						muxColor := "10";
						muxSprite := to_unsigned(i, 3);
					end if;
				end if;
			end loop;

			myColor := pixelColor;
			case muxColor is
			when "01" => myColor := MM0;
			when "10" => myColor := spriteColors(to_integer(muxSprite));
			when "11" => myColor := MM1;
			when others =>
				null;
			end case;
		
		
--			myColor := pixelColor;
--			for i in 7 downto 0 loop
--				if (MPRIO(i) = '0') or (pixelBgFlag = '0') then
--					if MC(i) = '1' then
--						case MCurrentPixel(i) is
--						when "01" => myColor := MM0;
--						when "10" => myColor := spriteColors(i);
--						when "11" => myColor := MM1;
--						when others => null;
--						end case;
--					elsif MCurrentPixel(i)(1) = '1' then
--						myColor := spriteColors(i);
--					end if;
--				end if;
--			end loop;
			
			if enaPixel = '1' then
				colorIndex <= myColor;

-- Krestage 3 debugging routine
--				if (cs = '1' and aRegisters = "011100") then
--					colorIndex <= "1111";
--				end if;
				if (LRBorder = '1') or (TBBorder = '1') then
					colorIndex <= EC;
				end if;
				if (hBlack = '1') then
					colorIndex <= (others => '0');
				end if;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Sprite to sprite collision
-- -----------------------------------------------------------------------
spriteSpriteCollision: process(clk)
		variable collision : unsigned(7 downto 0);
	begin
		if rising_edge(clk) then			
			if resetIMMC = '1' then
				IMMC <= '0';
			end if;

			if (myRd = '1')
			and	(aRegisters = "011110") then
				M2M <= (others => '0');
				M2Mhit <= '0';
			end if;

			for i in 0 to 7 loop
				collision(i) := MCurrentPixel(i)(1);
			end loop;
			if (collision /= "00000000")
			and (collision /= "00000001")
			and (collision /= "00000010")
			and (collision /= "00000100")
			and (collision /= "00001000")
			and (collision /= "00010000")
			and (collision /= "00100000")
			and (collision /= "01000000")
			and (collision /= "10000000")
			and (TBBorder = '0') then
				M2M <= M2M or collision;
				
				-- Give collision interrupt but only once until clear of register
				if M2Mhit = '0' then
					IMMC <= '1';
					M2Mhit <= '1';
				end if;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Sprite to background collision
-- -----------------------------------------------------------------------
spriteBackgroundCollision: process(clk)
	begin
		if rising_edge(clk) then			
			if resetIMBC = '1' then
				IMBC <= '0';
			end if;

			if (myRd = '1')
			and	(aRegisters = "011111") then
				M2D <= (others => '0');
				M2Dhit <= '0';
			end if;

			for i in 0 to 7 loop
				if MCurrentPixel(i)(1) = '1'
				and pixelBgFlag = '1'
				and (TBBorder = '0') then
					M2D(i) <= '1';
					
					-- Give collision interrupt but only once until clear of register
					if M2Dhit = '0' then
						IMBC <= '1';
						M2Dhit <= '1';
					end if;
				end if;
			end loop;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Generate IRQ signal
-- -----------------------------------------------------------------------
	IRQ <= (ILP and ELP) or (IMMC and EMMC) or (IMBC and EMBC) or (IRST and ERST);

-- -----------------------------------------------------------------------
-- Krestage 3 hack
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if phi = '1'
			and enaData = '1' then
				MC <= MCDelay;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Write registers
-- -----------------------------------------------------------------------
writeRegisters: process(clk)
	begin
		if rising_edge(clk) then
			resetLightPenIrq <= '0';
			resetIMMC <= '0';
			resetIMBC <= '0';
			resetRasterIrq <= '0';
		
			--
			-- write to registers
			if(reset = '1') then
				MX(0) <= (others => '0');
				MX(1) <= (others => '0');
				MX(2) <= (others => '0');
				MX(3) <= (others => '0');
				MX(4) <= (others => '0');
				MX(5) <= (others => '0');
				MX(6) <= (others => '0');
				MX(7) <= (others => '0');
				rasterCmp <= (others => '0');
				ECM <= '0';
				BMM <= '0';
				DEN <= '0';
				RSEL <= '0';
				yscroll <= (others => '0');
				ME <= (others => '0');
				RES <= '0';
				MCM <= '0';
				CSEL <= '0';
				xscroll <= (others => '0');
				MYE <= (others => '0');
				VM <= (others => '0');
				CB <= (others => '0');
				resetLightPenIrq <= '0';
				resetIMMC <= '0';
				resetIMBC <= '0';
				resetRasterIrq <= '0';
				ELP <= '0';
				EMMC <= '0';
				EMBC <= '0';
				ERST <= '0';
				MPRIO <= (others => '0');
				MCDelay <= (others => '0');
				MXE <= (others => '0');
				EC <= (others => '0');
				B0C <= (others => '0');
				B1C <= (others => '0');
				B2C <=(others => '0');
				B3C <= (others => '0');
				MM0 <= (others => '0');
				MM1 <= (others => '0');
				spriteColors(0) <= (others => '0');
				spriteColors(1) <= (others => '0');
				spriteColors(2) <= (others => '0');
				spriteColors(3) <= (others => '0');
				spriteColors(4) <= (others => '0');
				spriteColors(5) <= (others => '0');
				spriteColors(6) <= (others => '0');
				spriteColors(7) <= (others => '0');
				
			elsif (myWr = '1') then
				case aRegisters is
				when "000000" => MX(0)(7 downto 0) <= diRegisters;
				when "000001" => MY(0) <= diRegisters;
				when "000010" => MX(1)(7 downto 0) <= diRegisters;
				when "000011" => MY(1) <= diRegisters;
				when "000100" => MX(2)(7 downto 0) <= diRegisters;
				when "000101" => MY(2) <= diRegisters;
				when "000110" => MX(3)(7 downto 0) <= diRegisters;
				when "000111" => MY(3) <= diRegisters;
				when "001000" => MX(4)(7 downto 0) <= diRegisters;
				when "001001" => MY(4) <= diRegisters;
				when "001010" => MX(5)(7 downto 0) <= diRegisters;
				when "001011" => MY(5) <= diRegisters;
				when "001100" => MX(6)(7 downto 0) <= diRegisters;
				when "001101" => MY(6) <= diRegisters;
				when "001110" => MX(7)(7 downto 0) <= diRegisters;
				when "001111" => MY(7) <= diRegisters;
				when "010000" =>
					MX(0)(8) <= diRegisters(0);
					MX(1)(8) <= diRegisters(1);
					MX(2)(8) <= diRegisters(2);
					MX(3)(8) <= diRegisters(3);
					MX(4)(8) <= diRegisters(4);
					MX(5)(8) <= diRegisters(5);
					MX(6)(8) <= diRegisters(6);
					MX(7)(8) <= diRegisters(7);
				when "010001" =>
					rasterCmp(8) <= diRegisters(7);
					ECM <= diRegisters(6);
					BMM <= diRegisters(5);
					DEN <= diRegisters(4);
					RSEL <= diRegisters(3);
					yscroll <= diRegisters(2 downto 0);
				when "010010" =>
					rasterCmp(7 downto 0) <= diRegisters;
				when "010101" =>
					ME <= diRegisters;
				when "010110" =>
					RES <= diRegisters(5);
					MCM <= diRegisters(4);
					CSEL <= diRegisters(3);
					xscroll <= diRegisters(2 downto 0);

				when "010111" => MYE <= diRegisters;
				when "011000" =>
					VM <= diRegisters(7 downto 4);
					CB <= diRegisters(3 downto 1);
				when "011001" =>
					resetLightPenIrq <= diRegisters(3);
					resetIMMC <= diRegisters(2);
					resetIMBC <= diRegisters(1);
					resetRasterIrq <= diRegisters(0);
				when "011010" =>
					ELP <= diRegisters(3);
					EMMC <= diRegisters(2);
					EMBC <= diRegisters(1);
					ERST <= diRegisters(0);
				when "011011" => MPRIO <= diRegisters;
				when "011100" =>
					-- MC <= diRegisters;
					MCDelay <= diRegisters; -- !!! Krestage 3 hack
				when "011101" => MXE <= diRegisters;
				when "100000" => EC <= diRegisters(3 downto 0);
				when "100001" => B0C <= diRegisters(3 downto 0);
				when "100010" => B1C <= diRegisters(3 downto 0);
				when "100011" => B2C <= diRegisters(3 downto 0);
				when "100100" => B3C <= diRegisters(3 downto 0);
				when "100101" => MM0 <= diRegisters(3 downto 0);
				when "100110" => MM1 <= diRegisters(3 downto 0);
				when "100111" => spriteColors(0) <= diRegisters(3 downto 0);
				when "101000" => spriteColors(1) <= diRegisters(3 downto 0);
				when "101001" => spriteColors(2) <= diRegisters(3 downto 0);
				when "101010" => spriteColors(3) <= diRegisters(3 downto 0);
				when "101011" => spriteColors(4) <= diRegisters(3 downto 0);
				when "101100" => spriteColors(5) <= diRegisters(3 downto 0);
				when "101101" => spriteColors(6) <= diRegisters(3 downto 0);
				when "101110" => spriteColors(7) <= diRegisters(3 downto 0);
				when others => null;
				end case;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Read registers
-- -----------------------------------------------------------------------
readRegisters: process(clk)
	begin
		if rising_edge(clk) then
			case aRegisters is
			when "000000" => do <= MX(0)(7 downto 0);
			when "000001" => do <= MY(0);
			when "000010" => do <= MX(1)(7 downto 0);
			when "000011" => do <= MY(1);
			when "000100" => do <= MX(2)(7 downto 0);
			when "000101" => do <= MY(2);
			when "000110" => do <= MX(3)(7 downto 0);
			when "000111" => do <= MY(3);
			when "001000" => do <= MX(4)(7 downto 0);
			when "001001" => do <= MY(4);
			when "001010" => do <= MX(5)(7 downto 0);
			when "001011" => do <= MY(5);
			when "001100" => do <= MX(6)(7 downto 0);
			when "001101" => do <= MY(6);
			when "001110" => do <= MX(7)(7 downto 0);
			when "001111" => do <= MY(7);
			when "010000" =>
				do <= MX(7)(8) & MX(6)(8) & MX(5)(8) & MX(4)(8)
				& MX(3)(8) & MX(2)(8) & MX(1)(8) & MX(0)(8);
			when "010001" => do <= rasterY(8) & ECM & BMM & DEN & RSEL & yscroll;
			when "010010" => do <= rasterY(7 downto 0);
			when "010011" => do <= lpX;
			when "010100" => do <= lpY;
			when "010101" => do <= ME;
			when "010110" => do <= "11" & RES & MCM & CSEL & xscroll;
			when "010111" => do <= MYE;
			when "011000" => do <= VM & CB & '1';
			when "011001" => do <= IRQ & "111" & ILP & IMMC & IMBC & IRST;
			when "011010" => do <= "1111" & ELP & EMMC & EMBC & ERST;
			when "011011" => do <= MPRIO;
			when "011100" => do <= MC;
			when "011101" => do <= MXE;
			when "011110" => do <= M2M;
			when "011111" => do <= M2D;
			when "100000" => do <= "1111" & EC;
			when "100001" => do <= "1111" & B0C;
			when "100010" => do <= "1111" & B1C;
			when "100011" => do <= "1111" & B2C;
			when "100100" => do <= "1111" & B3C;
			when "100101" => do <= "1111" & MM0;
			when "100110" => do <= "1111" & MM1;
			when "100111" => do <= "1111" & spriteColors(0);
			when "101000" => do <= "1111" & spriteColors(1);
			when "101001" => do <= "1111" & spriteColors(2);
			when "101010" => do <= "1111" & spriteColors(3);
			when "101011" => do <= "1111" & spriteColors(4);
			when "101100" => do <= "1111" & spriteColors(5);
			when "101101" => do <= "1111" & spriteColors(6);
			when "101110" => do <= "1111" & spriteColors(7);
			when others => do <= (others => '1');
			end case;
		end if;
	end process;
end architecture;
