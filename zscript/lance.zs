// =====================================================================
// THE LANCE -- a real beam weapon for the UZDXREMA engine fork.
//
// Standalone extraction of RS_Main's RS_LaserGun. Descends from plain
// Weapon and does its own damage, so it drops into any mod.
//
// WHAT MAKES IT A BEAM AND NOT A FAST HITSCAN. The engine fork draws it by
// lighting every pixel by its distance from the segment -- Level.SetBeam,
// FORK_CHANGES.md section 13. It is not a sprite and not a chain of puffs:
// continuous at any length, wrapping floor/wall/ceiling as one unbroken
// object, visible hanging in the air, correctly vanishing behind walls, and
// the surfaces near it brighten because they ARE near it.
//
// AND IT DOES NOT FIRE. There are no shots. The beam is ON, and while it is
// on it deposits energy at a RATE -- damage is accumulated per tic as a real
// number and spent when it builds a whole point. No hitscans, no puffs, no
// cadence, no impact stutter.
//
// ---------------------------------------------------------------------
// NO AMMO. HEAT IS THE ONLY RESOURCE.
//
// Heat runs 0 to 100. Holding drives it up at 10/second -- ten full seconds
// before cook-off. Off the trigger there is a short grace, then it falls
// fast -- about three seconds back to cold, so the climb must be held and
// cannot be banked. Touch 100 and it locks out for a flat five seconds and
// comes back stone cold.
//
// SEVEN RUNGS, each a flat damage rate, and how many you climb through is
// your TIER -- see LNC_Lance.Tier. A tier-1 gun sees only the first.
//
//     heat     DPS     what it is
//     0-20      80     the sweeping band
//     20-40    140
//     40-60    240
//     60-80    420
//     80-100   750     the boss band
//
// Roughly x1.75 per rung, x9.4 end to end.
//
// WHY THIS CUTS FODDER LIKE A SHOTGUN BUT MAKES BOSSES A SIEGE, and it is
// not two systems -- it is one curve read from both ends:
//
//   A zombieman is 20hp and dies in a quarter second in band 1. An imp is
//   60hp, three quarters of a second. You never leave the bottom band, so
//   sweeping a room of fodder costs almost NO HEAT -- the gun is still cold
//   when the room is empty. That is the shotgun feeling: point, they fall,
//   move on.
//
//   A Baron is 1000hp. Band 1 would need twelve and a half seconds and you
//   cook off at four, so band 1 CANNOT kill it -- the weapon physically
//   cannot brute-force a boss from cold. You have to climb, and climbing
//   means holding, and holding is the thing that overheats you.
//
//   A full four-second hold from cold to cook-off delivers about 1300
//   damage, of which the top band alone is 600. So nearly half a full
//   burn's output lives in the last four fifths of a second, and reaching
//   it costs you the five-second lockout if you misjudge by a hair.
//
// A Cyberdemon at 4000hp is three full burns and two lockouts: roughly
// twenty-five seconds of committed, exposed, cannot-move-freely fire. Which
// is the whole point, because the beam is also a flare that tells the room
// exactly where you are standing.
// ---------------------------------------------------------------------
//
// TWO HANDS, TWO BEAMS. LNC_Lance is mainhand and LNC_LanceOffhand is
// offhand. Each owns its own beam slot and its own heat, so firing one
// never disturbs the other -- which is why stopping releases only its own
// slot rather than calling ClearBeams(). Alternating hands is a real
// technique: one cools while the other burns.
//
// ENGINE DEPENDENCY, stated plainly: Level.SetBeam / SetBeamAnchor /
// ClaimBeam / ReleaseBeam / IsBeamClaimed / SetBeamStyleScroll are natives of
// this fork, and the tracked-hand positions (AttackPos / OffhandPos /
// OverrideAttackPosDir) come from its VR lineage. SetBeamStyleScroll is the
// newest of them (2026-10-01) and exists because scroll depth was scene-wide,
// so this weapon and the grab lasers could not both have the beam they want.
// On stock GZDoom this file does not compile. That is the deal.
// =====================================================================

class LNC_Lance : Weapon
{
	// HEAT IS THE WEAPON, and it is the only resource. Everything visible
	// and everything damaging derives from it. A double rather than an int
	// because the rates are per-second and the bands need to be crossed
	// smoothly, not in whole-number jumps.
	double heat;          // 0 .. LNC_HEAT_MAX

	// Tics remaining in the post-cook-off lockout. Counted down in DoEffect
	// so it runs whether or not the weapon is selected -- switching hands to
	// dodge your own cooldown would defeat the entire cost.
	int lockTics;

	bool firing;          // was the beam live last tic, for edge detection

	// THE CHANNEL THE LOOP IS ACTUALLY PLAYING ON, latched the tic it starts.
	// Deliberately NOT re-derived when stopping it: DoEffect's safety Release
	// runs precisely when this weapon has LEFT the hand, so asking "which hand
	// am I?" at that point answers with the other hand's channel and the loop
	// goes on playing forever with nothing on screen to explain it.
	int activeLoopChan;

	// Fractional damage carried between tics. Doom's damage is an integer
	// event but a beam's damage is a rate; this is where the remainder
	// lives so the rate comes out exact rather than truncated to nothing.
	double burn;

	// THE SACRED POINTER, for GunBonsai.
	//
	// GunBonsai decides WHICH WEAPON earned the XP by reading
	// evt.inflictor.master -- the pointer every projectile in RS_Main sets
	// to the weapon that fired it. A beam has no projectile, so the burn
	// would otherwise pass the player pawn as its own inflictor, whose
	// master is null, and GunBonsai would fall back to ReadyWeapon.
	//
	// That is right for the mainhand and WRONG for the offhand: an offhand
	// Lance would quietly feed all its XP to whatever is in the other hand.
	//
	// So each Lance keeps one invisible marker whose master is itself, and
	// hands that to DamageMobj as the inflictor. One actor per weapon, made
	// once and reused for the life of the gun -- not one per damage tick,
	// which at this cadence would be dozens of actors a second.
	//
	// It is also placed at the player before each burn so knockback still
	// pushes away from the shooter rather than from wherever it was last.
	LNC_BeamInflictor tag;

	LNC_BeamInflictor GetTag(Actor from)
	{
		if (!tag)
		{
			tag = LNC_BeamInflictor(Spawn("LNC_BeamInflictor", from.Pos));
			if (tag) tag.master = self;
		}
		if (tag) tag.SetOrigin(from.Pos, false);
		return tag;
	}

	// GEAR-CHANGE PUNCH. Crossing into a new band is the most important
	// thing that happens to this weapon while you hold it, and a colour
	// swap alone is easy to miss when you are looking at what you are
	// killing. Band changes therefore flash: the whole beam goes white and
	// fat for a few tics. Reads in peripheral vision, which is where you
	// actually are.
	int lastBand;
	int flashTics;

	// Tics of off-trigger grace left before heat starts bleeding. Refilled
	// every tic the beam is live -- see DoEffect.
	int graceLeft;

	// ---- the heat model, all of it -------------------------------------
	// SLOWED 2026-08-14 on the owner's call: "have it last longer, make it
	// take longer to get to the higher levels of damage without dying on
	// me." Was 25/sec, cooking off in four; now 10/sec, so ten full seconds
	// of hold and two whole seconds in every band. The climb becomes
	// something you commit to across a fight rather than a sprint.
	const LNC_HEAT_MAX  = 100.0;
	// Volumetric slot 0, stated rather than defaulted. The fog glow follows the lowest
	// live slot (FLevelLocals::FirstVolBeam), so 0 keeps the Lance's look exactly;
	// the torch holds 1 and the weapon wheel 2.
	const VOLBEAM_SLOT = 0;
	const LNC_HEAT_RISE = 10.0;    // per second firing -> 10.0s cold to max

	// COOLING, AND IT IS FAST ON PURPOSE.
	//
	// The owner's ask: "when I stop firing the laser, it needs a few tics to
	// cool down back to the original damage output and colour."
	//
	// Two parts, because a single rate cannot do both jobs. A short GRACE
	// where nothing bleeds at all, so that squeezing off two quick bursts at
	// the same target does not cost you the rung you just climbed -- then a
	// FAST fall, so that genuinely stopping drops you back to blue in about
	// three seconds rather than the twelve the old bleed took.
	//
	// The grace is what keeps the weapon usable; the fast fall is what makes
	// the climb something you have to hold rather than something you bank.
	const LNC_HEAT_GRACE = 8;      // tics off-trigger before cooling starts
	const LNC_HEAT_FALL  = 32.0;   // per second idle -> ~3.1s max to cold
	const LNC_LOCKOUT    = 175;    // tics -- a flat 5.0 seconds

	// Seven rungs. The ladder's height is a per-player upgrade; see Tier().
	const LNC_MAX_TIER  = 7;

	const LNC_RANGE     = 2200.0;

	// THE SYNTHETIC MUZZLE. In VR the tracked controller is a real world
	// position; on a desktop the weapon is a screen overlay with no world
	// position at all, so the point the beam appears to leave has to be
	// built relative to the eye. These three are the tuning knobs: right and
	// up put the beam at the gun in the corner rather than in the middle of
	// your face, forward keeps its halo off the camera.
	const LNC_MUZZLE_FWD   = 16.0;
	const LNC_MUZZLE_RIGHT = 10.0;
	const LNC_MUZZLE_UP    = -8.0;

	Default
	{
		Tag "Lance";
		Weapon.SelectionOrder 1080;
		Weapon.SlotNumber 6;

		// NO AMMO -- AND THE AMMO COUNTER IS THE HEAT GAUGE.
		//
		// There is an ammo TYPE, but nothing is ever spent: AmmoUse is 0 and
		// AMMO_OPTIONAL lets it fire at zero. The type exists purely so the
		// stock HUD has something to print, and DoEffect drives that number
		// straight from heat. That buys a readout on every status bar, every
		// alt-HUD and every third-party HUD in existence for no HUD code at
		// all -- they all already know how to show ammo.
		//
		// AmmoGive1 IS 0 on purpose. Picking the weapon up must not hand you
		// a hundred heat.
		Weapon.AmmoUse 0;
		Weapon.AmmoGive1 0;
		Weapon.AmmoType1 "LNC_Heat";

		Inventory.PickupMessage "You got the Lance!";
		Inventory.Icon "PLASA0";   // Vanilla, matching MeatGrinder -- its PlasmaThrower spawns as PLAS A (weapons.txt:563), so the Bolter never had a custom pickup sprite by design. The WORLD drop still wears the Bolter model bound to that same PLAS A frame (MODELDEF), so what lies on the floor is the gun itself.
		+WEAPON.NOHANDSWITCH;
		+WEAPON.AMMO_OPTIONAL;
		+WEAPON.NOALERT;

		// Where the beam leaves the gun in VR. Stock property of this fork's
		// Weapon class; the engine's own laser sight reads it too, so setting
		// it here moves both together. COMPONENT ORDER IS NOT XYZ --
		// hw_weapon.cpp applies .Y along FORWARD and .X sideways.
		Weapon.LaserBeamOffset (0.0, 22.0, 0.0);
	}

	// 0 at stone cold, 1 at cook-off. Drives every visual.
	clearscope double Charge() const
	{
		return clamp(heat / LNC_HEAT_MAX, 0.0, 1.0);
	}

	// Heat as the 0-100 number, for a HUD or a readout.
	clearscope int HeatPercent() const
	{
		return int(clamp(heat, 0.0, LNC_HEAT_MAX) + 0.5);
	}

	// Which of the five bands, 0-4. Exposed because the visuals step with
	// it as well -- the beam should look like it changed gear, not merely
	// like it got slightly brighter.
	// ---- TIER: how far up the ladder this gun can climb ------------------
	//
	// One counter, held by the PLAYER rather than by either weapon, so both
	// hands are always the same tier. Two Lances at different power would be
	// unreadable -- you would have to remember which hand was which.
	//
	// Starts at 1: one colour, one damage rate, a flat beam. Every Lance
	// picked up afterwards adds a rung, to a maximum of LNC_MAX_TIER.
	// ---- THE ARSENAL'S POWER, IN ONE PLACE -------------------------------
	//
	// Read by both hands, so the pair always shows the same colour for the
	// same strength. "Same colours means stronger" only works if there is one
	// number behind it.
	//
	// Three inputs, in order:
	//
	//   1. THE MODE. lnc_progression 0 is the original -- the whole ladder
	//      available from heat alone, no pickups, which is the behaviour in
	//      the repo's screenshots. 1 gates the ceiling behind found cores.
	//
	//   2. THE TIER, from cores, when that mode is on.
	//
	// There was a third input here -- a battery fed by a buckler that absorbed
	// what it stopped, which bought temporary rungs. The buckler is gone, and
	// the battery went with it rather than being left as a source with nothing
	// feeding it.
	static clearscope int ArsenalTier(Actor holder)
	{
		if (!holder) return 1;

		if (LNC_Lance.ModeProgression() == 0)
			return LNC_MAX_TIER;                       // the original: all of it

		return clamp(holder.CountInv("LNC_LanceTier"), 1, LNC_MAX_TIER);
	}

	static clearscope int ModeProgression()
	{
		let cv = CVar.GetCVar("lnc_progression");
		return cv ? cv.GetInt() : 1;
	}

	clearscope int Tier() const
	{
		return LNC_Lance.ArsenalTier(owner);
	}

	// THE HEAT BAR IS SUBDIVIDED BY TIER, NOT CAPPED BY IT.
	//
	// This is the part that makes the upgrade feel like a change of weapon
	// rather than a bigger number. Heat always runs the same 0-100 and
	// always starts at the bottom -- what the tier changes is how many rungs
	// that climb passes through.
	//
	//     tier 1   one band       the whole bar is a single flat beam
	//     tier 2   two bands      halfway up, it gears once
	//     tier 7   seven bands    six gear changes across the same ten seconds
	//
	// Capping instead -- fixed 1/7th-wide bands with the top ones simply
	// unreachable -- would mean a tier-2 gun spent 70% of its heat bar doing
	// nothing, and the bar would read as mostly wasted. This way every rung
	// of heat you build always buys something, at every tier.
	clearscope int Band() const
	{
		int t = Tier();
		int b = int(Charge() * t);
		return clamp(b, 0, t - 1);
	}

	// FLAT WITHIN EACH BAND, as specified. Not a smooth curve: the steps are
	// the point. You should be able to FEEL the gear change -- a smooth ramp
	// gives you no moment to recognise, so there is nothing to aim for and
	// nothing to hold at.
	//
	// x1.75 per rung. See the header for why this shape splits fodder from
	// bosses without needing a second system to do it.
	// THE BASE RATE, SET BY TIER. What the gun does cold.
	//
	// THE ANCHOR IS ONE GUN ON A ZOMBIEMAN AT TIER 1: six seconds. 20hp over
	// six seconds is 3.3, and everything else scales up from there.
	//
	// Seven rungs, geometric at about x1.62 each, so no tier is a dead step
	// and the top is roughly eighteen times the bottom.
	//
	//     tier   DPS     one gun    both guns
	//     1       3.3    6.1 s      3.0 s
	//     2       5.4    3.7 s      1.9 s
	//     3       8.7    2.3 s      1.1 s
	//     4      14.0    1.4 s      0.7 s
	//     5      23.0    0.9 s      0.4 s
	//     6      37.0    0.5 s      0.3 s
	//     7      60.0    0.33 s     0.17 s
	//
	// PER GUN, and both hands trace the same aim -- so on a single target the
	// rate is double the column above. That is the point of the second Lance
	// and it is not meant to be cancelled out here.
	//
	// IT USED TO BE INDEXED BY BAND ALONE, and that could not express this.
	// A band comes from heat, heat starts at zero, so a tier-7 gun opened
	// fire at exactly the same rate as a tier-1 one and only pulled ahead
	// once it warmed up -- which means "a third of a second at max tier"
	// was unreachable against a fresh target no matter what the numbers
	// were. Tier has to scale the base for the ask to mean anything.
	double TierBase() const
	{
		switch (Tier())
		{
			case 1:  return 3.3;
			case 2:  return 5.4;
			case 3:  return 8.7;
			case 4:  return 14.0;
			case 5:  return 23.0;
			case 6:  return 37.0;
			default: return 60.0;
		}
	}

	// HEAT ON TOP, x1 cold to x2.5 at the top band.
	//
	// Stepping with the BAND rather than smoothly with heat, because the
	// colour is the only damage gauge this weapon has and it steps. A rate
	// that slid continuously under a stepped colour would make the gauge a
	// liar. A tier-1 gun has a single band and so gets no multiplier, which
	// is right: it has no colour change either.
	double DPS() const
	{
		int t = Tier();
		if (t <= 1) return TierBase();

		double f = double(Band()) / double(t - 1);
		return TierBase() * (1.0 + 1.5 * f);
	}

	// ---- BEAM SLOT BUDGET ----------------------------------------------
	//
	// Eight slots exist, level-global, and each one costs a per-pixel
	// segment test across the whole screen -- twice, once for surface
	// lighting and once for the glow in the air. So they are a budget, not
	// a free ceiling, and this weapon spends all of it:
	//
	//     0        mainhand core beam
	//     1        offhand core beam
	//     2,3,4    mainhand helix
	//     5,6,7    offhand helix
	//
	// Three chords is a coarse helix -- each spans 120 degrees of the turn
	// -- but chords are exactly what a beam slot IS, and three rotating
	// ones read as a twisting ribbon wrapped round the core rather than as
	// a triangle. Splitting them evenly rather than giving one hand a finer
	// spiral keeps the two hands identical, which matters more.
	int BeamSlot()
	{
		if (owner && owner.player && owner.player.OffhandWeapon == self) return 1;
		return 0;
	}

	// ONE LOOP CHANNEL PER HAND, AND NEITHER OF THEM THE ENGINE'S.
	//
	// The loop used to run on CHAN_5 for both hands, which was wrong twice
	// over. CHAN_5 *is* CHAN_OFFWEAPON (engine base.zs): A_StartSound moves an
	// offhand weapon's CHAN_WEAPON sounds onto 5, so the offhand Lance's own
	// charge sound -- and every offhand sound any other mod plays -- landed on
	// top of the loop and cut it. And with both hands sharing one channel, the
	// second Lance to fire restarted the first's loop, the two per-tic pitch
	// writes fought each other, and releasing either trigger silenced both.
	//
	// Numbers of our own, clear of the engine's 0..7 block and of
	// RS_Lightsaber's hum channels (20, 21), since both can be held at once.
	const LOOP_CHAN_MAIN = 22;
	const LOOP_CHAN_OFF  = 23;

	int LoopChan() { return BeamSlot() == 1 ? LOOP_CHAN_OFF : LOOP_CHAN_MAIN; }

	// ---- OUR FOUR SLOTS, CLAIMED, NOT ASSUMED ---------------------------
	//
	// This used to take slots 0-7 by number and set the scene-wide beam count
	// and look itself. Both were wrong the moment anything else drew a beam,
	// and something does: RS_WorldHands' grab lasers write slots 0 and 1 and
	// force the count to 2 every tic (rs_grabviz.zs), from a handler that runs
	// AFTER the weapon (p_tick.cpp runs P_PlayerThink before WorldTick). So
	// the Lance's beam was being overwritten and counted out of existence on
	// every tic it fired -- which is why it was very probably invisible in the
	// owner's full load order rather than in isolation.
	//
	// Now: four slots claimed from the engine, three layers and the cook glow.
	// The claim is ours until we release it or this weapon is destroyed, and
	// nothing else can be handed it. Claims do NOT survive a map change or a
	// savegame load, so HoldBeams re-claims when the map key moves -- the same
	// shape WM_Unmaker uses (unmaker.zs HoldBeams).
	int  lncBeam0, lncBeam1, lncBeam2, lncCook;
	bool lncBeamHeld;
	int  lncBeamMapKey;

	int MapKey() const { return level.totaltime - level.maptime; }

	int LayerSlot(int i) const
	{
		return i == 2 ? lncBeam2 : (i == 1 ? lncBeam1 : lncBeam0);
	}

	bool HoldBeams()
	{
		if (lncBeamHeld && lncBeamMapKey == MapKey()
			&& level.IsBeamClaimed(lncBeam0) && level.IsBeamClaimed(lncBeam1)
			&& level.IsBeamClaimed(lncBeam2) && level.IsBeamClaimed(lncCook))
			return true;

		lncBeamHeld = false;
		int s0 = level.ClaimBeam(self);
		int s1 = level.ClaimBeam(self);
		int s2 = level.ClaimBeam(self);
		int sc = level.ClaimBeam(self);
		if (s0 < 0 || s1 < 0 || s2 < 0 || sc < 0)
		{
			// All four or none: a partial claim would draw a stack missing a
			// layer, which reads as a broken beam rather than as no beam.
			if (s0 >= 0) level.ReleaseBeam(s0);
			if (s1 >= 0) level.ReleaseBeam(s1);
			if (s2 >= 0) level.ReleaseBeam(s2);
			if (sc >= 0) level.ReleaseBeam(sc);
			return false;
		}

		lncBeam0 = s0; lncBeam1 = s1; lncBeam2 = s2; lncCook = sc;
		lncBeamMapKey = MapKey();
		lncBeamHeld = true;

		// OUR LOOK, PER SLOT, INCLUDING THE SCROLLING -- and the scrolling is
		// the reason this needs SetBeamStyleScroll rather than SetBeamStyle.
		//
		// Scroll depth is the beading: main.fp does
		//     bright *= 1.0 + depth * sin(along * 0.06 - timer*speed)
		// and that sine is the ONLY periodic term in the whole beam shader.
		// Wavelength is 2*pi/0.06 ~= 105 world units, so across a room it is
		// about ten bright/dark bands: (gun) -0-0-0-0-0-. A capital-ship lance
		// is one solid unbroken bar, so depth is ZERO here and it stays zero.
		// The engine's scene default is 0.25 and the grab lasers want 0.25,
		// which is right for them -- beads are what a grab laser should look
		// like. Both can now be true at once, which is the whole point of the
		// per-slot form.
		//
		// Speed is kept non-zero so that turning depth on to look at something
		// does not also need this line changed.
		//
		// airGlow, halo, taper, flare. The sheath is wide and soft, the core
		// tight and bright, the filament thin and dim; none of them taper much,
		// because a lance is a bar and not a cone.
		level.SetBeamStyleScroll(lncBeam0, 1.00, 0.85, 0.10, 1.20, 6.0, 0.0);
		level.SetBeamStyleScroll(lncBeam1, 1.00, 0.35, 0.10, 1.40, 6.0, 0.0);
		level.SetBeamStyleScroll(lncBeam2, 0.80, 0.25, 0.10, 1.00, 6.0, 0.0);
		// The cook glow is a hot spot on the thing being burned, not a line:
		// all halo, no taper, and a strong flare where it lands.
		level.SetBeamStyleScroll(lncCook, 1.00, 1.00, 0.00, 2.00, 6.0, 0.0);
		return true;
	}

	void DropBeams()
	{
		if (!lncBeamHeld) return;
		level.ReleaseBeam(lncBeam0);
		level.ReleaseBeam(lncBeam1);
		level.ReleaseBeam(lncBeam2);
		level.ReleaseBeam(lncCook);
		lncBeamHeld = false;
	}

	// ---- THE COOK -------------------------------------------------------
	//
	// How much has been poured into the thing currently under the beam.
	// Tracked per WEAPON rather than per victim: the beam only ever burns one
	// actor at a time, so a single accumulator and a note of who it belongs
	// to is enough, and it costs nothing on the monsters.
	Actor  cookTarget;
	double cookAmt;

	// A HOT SPOT THAT GROWS WHERE THE BEAM IS LANDING.
	//
	// Not a flame and not a decal -- a beam of almost no length, which the
	// segment solver lights as a small sphere. It starts as a pinprick on
	// contact and swells as the target takes damage, so a thing visibly cooks
	// before it dies. On a boss it is the only feedback that a long hold is
	// achieving anything at all.
	//
	// SCALED AGAINST SPAWN HEALTH, so it is full right as the thing dies
	// whether that is a zombieman or a Baron. A fixed threshold would fill
	// instantly on fodder and never fill on anything big.
	void DrawCookGlow(Vector3 where, Actor victim)
	{
		double maxhp = victim ? double(victim.SpawnHealth()) : 100.0;
		if (maxhp < 1.0) maxhp = 1.0;

		double f = clamp(cookAmt / maxhp, 0.0, 1.0);

		// SQUARED, because "start super small". Linear growth is already a
		// third of the final size after a third of the damage, which reads as
		// popping into existence rather than kindling.
		double g = f * f;

		// Orange into white-hot. Intensity climbs past 1.0 deliberately: the
		// scene renders to a float target and the bloom pass thresholds at
		// 1.0, so the top of this range blooms on its own without a dynamic
		// light being involved.
		Color col = LNC_Lance.LerpCol(0xFF5A08, 0xFFD070, f);

		// Given a hair of length rather than a true zero, so nothing in the
		// air-glow pass has to divide by a null direction.
		if (!HoldBeams()) return;
		level.SetBeam(lncCook, where, where + (0, 0, 0.05),
			0.25 + 3.00 * g,
			0.40 + 5.00 * g,
			col,
			0.20 + 1.50 * g);
	}

	// ---- THE THREE-LAYER BEAM -------------------------------------------
	//
	// The owner's shape, from watching it fire: "this dense, solid beam
	// firing in a slow circular motion, inside of a softer, larger beam."
	//
	//     SHEATH     wide, soft, dim, dead on the axis. The volume.
	//     CORE       dense, thin, bright. Its MUZZLE END orbits slowly.
	//     FILAMENT   thinner still, orbiting the other way, wider radius.
	//
	// ONLY THE START MOVES. Both far ends stay pinned to the impact point,
	// so the moving layers CONVERGE on the target rather than sliding off
	// it -- the beam looks stirred at the barrel and perfectly accurate at
	// the other end, which is both the nicer read and the honest one, since
	// the damage lands where the far end is.
	//
	// AND THIS REPLACES THE HELIX ENTIRELY, which is a straight upgrade.
	// A helix had to be built from chords -- three per hand was the whole
	// slot budget -- and three straight chords rotating about an axis is a
	// spinning triangle, which is exactly why it read as a gatling barrel.
	// These are SINGLE straight beams whose endpoints move, so there is no
	// polyline, no faceting, and nothing to approximate. The motion is
	// perfectly smooth because there is no geometry being subdivided.
	//
	// THE BASIS IS BUILT FROM THE AXIS AND NOTHING ELSE -- no hand matrices,
	// no cvars, no engine convention to mirror. Just "any two directions
	// perpendicular to this line".
	void DrawBeamStack(Vector3 a, Vector3 b, int band, double flash,
		Color col, Color innerCol)
	{
		// No slots, no beam. Better than drawing into someone else's.
		if (!HoldBeams()) return;

		// ---- THE ORIGIN IS THE GUN, RESOLVED EVERY FRAME -------------------
		//
		// THIS IS THE JITTER FIX AND IT IS NOT A SMOOTHING PASS.
		//
		// `a` below is AttackPos, which hw_vrmodes.cpp rewrites from the live
		// controller transform EVERY FRAME -- 90Hz and up. This code runs at 35.
		// So every value of `a` handed to SetBeam is a stale sample of a value
		// that has already moved on, and interpolating between two stale samples
		// cannot recover the motion between them. The beam stepped while the
		// world glided, and it got worse the faster you moved, because the
		// disagreement grows with speed.
		//
		// Anchored, the renderer ignores the start point in SetBeam entirely and
		// reads the hand's CURRENT position in the frame it is drawing. The beam
		// leaves the muzzle and stays there.
		//
		// ONLY THE START IS ANCHORED. The far end is a hit location in the
		// world, which genuinely only changes once a tic and is interpolated
		// correctly already -- anchoring it too would drag the impact point
		// around with your wrist.
		//
		// All three stacked beams share the muzzle, so all three anchor.
		int anchor = (BeamSlot() == 1) ? 2 : 1;      // 2 = off hand, 1 = main
		level.SetBeamAnchor(lncBeam0, anchor);
		level.SetBeamAnchor(lncBeam1, anchor);
		level.SetBeamAnchor(lncBeam2, anchor);

		Vector3 axis = b - a;
		double len = axis.Length();
		if (len < 2.0) { ClearBeams(); return; }
		axis /= len;

		Vector3 u = ((0, 0, 1) cross axis);
		if (u dot u < 1e-6) u = ((1, 0, 0) cross axis);
		double ul = u.Length();
		if (ul < 1e-6) { ClearBeams(); return; }
		u /= ul;
		Vector3 v = (axis cross u);      // unit by construction

		double step = double(band);

		// --- THE SHEATH. Wide and soft and deliberately DIM: it is the
		// atmosphere the core burns inside, not a second beam. Its intensity
		// stays low so it never competes with the core for the eye, and so
		// the two together do not stack past the bloom threshold except at
		// the very top band.
		// SIZED DOWN HARD. The first pass at these numbers produced wide
		// diagonal shafts of light crossing the whole view instead of a
		// beam, and the reason is `soft` rather than `thick`: main.fp lights
		// out to thick + soft*8, so a soft of 5.0 is a FORTY-TWO UNIT glow
		// radius. Starting that twenty units from the eye fills the screen.
		//
		// A tier-1 laser wants to be thin and precise. It earns its width by
		// climbing the ladder, not by default.
		double sheathThick = 0.9 + 0.45 * step + 0.8 * flash;
		level.SetBeam(lncBeam0, a, b,
			sheathThick,
			1.6 + 0.8 * step + 1.2 * flash,      // soft: reach ~14 units cold
			col,
			0.15 + 0.06 * step + 0.25 * flash);

		// --- THE CORE. Dense, tight, bright, and stirred.
		//
		// SLOW, as asked. 2.2 degrees a tic is about a revolution every five
		// seconds -- fast enough to be unmistakably moving, slow enough that
		// it reads as a deliberate motion rather than a spin. Speeds up only
		// slightly with heat, so the top band feels agitated instead of
		// frantic.
		double coreAng = Level.maptime * (2.2 + 0.5 * step);

		// THE ORBIT IS MEASURED AGAINST THE SHEATH, NOT IN ABSOLUTE UNITS,
		// and that is the fix for "the circulating laser is not there for the
		// first few tics."
		//
		// It was a flat 2.2 + 0.9*step while the sheath's dense middle was
		// 2.4 + 1.5*step. At band 0 the orbit was SMALLER than the sheath
		// core, so the circulating beam was inside the solid part of the
		// sheath and simply could not be seen -- and because the sheath grew
		// faster per band than the orbit did, it stayed buried at every band.
		// The only time it showed was during a gear-change flash, which adds
		// 2.0 to the radius for five tics.
		//
		// Expressed as a multiple of the sheath instead, the core always
		// rides outside the solid middle and inside the halo, at every band
		// and from the very first tic of the very first shot.
		// THE ORBIT CONVERGES AT THE MUZZLE.
		//
		// It used to offset the START point, which is what put the core and
		// the filament visibly leaving from ABOVE and BELOW the barrel rather
		// than out of it -- an offset of five or seven units, twenty units
		// from the eye, is a huge angle on screen even though it is nothing
		// in world terms.
		//
		// So the moving end is the FAR end now, and the near end stays pinned
		// to the muzzle with everything else. All three layers leave the
		// barrel from one point and separate along their length, which is
		// both what a real emitter does and what stops the weapon looking
		// like three guns bolted together.
		//
		// The far end is hundreds of units away, so the same few units of
		// offset there is a slow subtle wander instead of a wide arc -- which
		// is the motion that was wanted in the first place.
		double coreRad = 0.9 + 0.5 * step + 0.8 * flash;
		Vector3 coreOff = (u * cos(coreAng) + v * sin(coreAng)) * coreRad;
		level.SetBeam(lncBeam1, a, b + coreOff,
			0.42 + 0.16 * step + 0.7 * flash,
			0.55 + 0.24 * step + 0.8 * flash,
			innerCol,
			0.48 + 0.15 * step + 0.45 * flash);

		// --- THE FILAMENT. Counter-rotating, wider orbit, thinner and
		// dimmer. Two things turning opposite ways is what stops the stack
		// reading as one rigid object being waved about -- it gives the
		// beam internal motion instead of just motion.
		//
		// Offset 140 degrees at t=0 so the two are never briefly coincident
		// at the start of a burst, which would look like a glitch.
		double filAng = 140.0 - Level.maptime * (1.5 + 0.35 * step);
		double filRad = 1.5 + 0.7 * step + 1.1 * flash;
		Vector3 filOff = (u * cos(filAng) + v * sin(filAng)) * filRad;
		level.SetBeam(lncBeam2, a, b + filOff,
			0.20 + 0.08 * step,
			0.38 + 0.16 * step + 0.5 * flash,
			innerCol,
			0.24 + 0.10 * step + 0.35 * flash);
	}

	void ClearBeams()
	{
		// Nothing claimed means nothing of ours is drawn, so there is nothing
		// to blank -- and blanking by number here is exactly what used to walk
		// over another mod's slots.
		if (!lncBeamHeld) { cookTarget = null; cookAmt = 0.0; return; }

		for (int i = 0; i < 3; i++)
		{
			// ANCHOR OFF FIRST. A dark slot that is still anchored would hand
			// the next thing to use it an origin stuck to a controller it never
			// asked about -- and that beam would look right until you moved
			// your arm. The engine clears these too when a slot goes dark, but
			// a caller that releases its own slots should not rely on that.
			level.SetBeamAnchor(LayerSlot(i), 0);
			level.SetBeam(LayerSlot(i), (0, 0, 0), (0, 0, 0), 0.01, 0.01, 0, 0.0);
		}

		// The cook glow sits outside the three-layer block, so it has to be
		// released here as well or a hot spot stays burning in mid-air after
		// the trigger comes up. Forgetting the target with it means the next
		// thing you touch starts cold instead of inheriting this one's cook.
		level.SetBeam(lncCook, (0, 0, 0), (0, 0, 0), 0.01, 0.01, 0, 0.0);
		cookTarget = null;
		cookAmt = 0.0;

		// The slots stay CLAIMED while the weapon lives. Releasing them on
		// every trigger release would hand them to whatever asked next and make
		// the following shot fight for them again -- and the engine releases
		// them for us when this weapon is destroyed, because the claim named an
		// owner. Blanked, not given back.
	}

	// ---- colour ---------------------------------------------------------
	//
	// Five bands, five genuinely different colours rather than five steps
	// along one ramp -- the band is information and it should be readable at
	// a glance, in peripheral vision, while you are looking at something
	// else. A blue beam and an orange beam are not the same weapon.
	//
	// Blue to cyan to white is "cold and building"; gold to furnace-red is
	// "this is about to cost you". The core carries the heat, and the helix
	// carries the contrast against it.
	static Color HueCol(double h, double sat, double val)
	{
		h -= floor(h);
		double i = floor(h * 6.0);
		double f = h * 6.0 - i;
		double p = val * (1.0 - sat);
		double q = val * (1.0 - sat * f);
		double t = val * (1.0 - sat * (1.0 - f));
		double r, g, b;
		int seg = int(i) % 6;
		if      (seg == 0) { r = val; g = t;   b = p;   }
		else if (seg == 1) { r = q;   g = val; b = p;   }
		else if (seg == 2) { r = p;   g = val; b = t;   }
		else if (seg == 3) { r = p;   g = q;   b = val; }
		else if (seg == 4) { r = t;   g = p;   b = val; }
		else               { r = val; g = p;   b = q;   }
		return Color(255, int(r * 255), int(g * 255), int(b * 255));
	}

	// SEVEN COLOURS, ONE PER RUNG. The hue no longer drifts on a timer --
	// colour now carries INFORMATION, and a number that means something must
	// not also be wandering on its own.
	//
	// Read two ways at once, which is the point: within a burst it tells you
	// how hot you are, and across a run it tells you how far up the ladder
	// your gun has come. A tier-1 player only ever sees deep blue. Seeing
	// magenta at all means somebody is carrying a fully built Lance.
	//
	// Cold end to hot end, and deliberately not a single ramp -- green in
	// the middle breaks blue-to-red into two halves so adjacent rungs are
	// never nearly the same colour.
	// STATIC, so anything that wants the ladder can read it without owning a
	// Lance. "Same colours means stronger" only holds if there is literally
	// one table -- two copies would drift the first time either was tuned.
	static Color BandColor(int band)
	{
		switch (band)
		{
			case 0:  return 0x2050FF;   // deep electric blue
			case 1:  return 0x00D8FF;   // cyan
			case 2:  return 0x40FF80;   // green
			case 3:  return 0xFFF0A0;   // pale gold
			case 4:  return 0xFFA020;   // amber
			case 5:  return 0xFF3A10;   // furnace
			default: return 0xFF40FF;   // magenta: the top of the ladder
		}
	}

	Color CoreColor() const
	{
		switch (Band())
		{
			case 0:  return 0x2050FF;   // deep electric blue
			case 1:  return 0x00D8FF;   // cyan
			case 2:  return 0x40FF80;   // green
			case 3:  return 0xFFF0A0;   // pale gold
			case 4:  return 0xFFA020;   // amber
			case 5:  return 0xFF3A10;   // furnace
			default: return 0xFF40FF;   // magenta: the top of the ladder
		}
	}

	// Deliberately NOT a lighter version of the core. The spiral should be a
	// separate object wrapped around the beam, and the only way three thin
	// chords read as separate at speed is if they are a different colour.
	// The top band's magenta on furnace-red is the loudest thing the weapon
	// ever does, which is correct: it is also the most dangerous.
	// THE CORE'S OWN COLOUR, LIFTED TOWARD WHITE. Not a contrasting hue: the
	// stirred core and the filament are one object with the sheath, and
	// giving the inner layers their own colour made them look like two
	// unrelated weapons firing down the same line.
	Color HelixColor() const
	{
		return LNC_Lance.LerpCol(CoreColor(), 0xFFFFFF, 0.55);
	}

	// ---- the beam ------------------------------------------------------
	//
	// Called once per tic while the trigger is down. Traces, draws, burns.
	action void A_LanceBeam()
	{
		let w = LNC_Lance(invoker);
		if (!w || !self || !player) return;

		// Heat climbs from the very first tic. There is no free window --
		// with no ammo, heat is the only cost the weapon has, so nothing
		// about firing may be free.
		w.heat += LNC_HEAT_RISE / 35.0;

		if (w.heat >= LNC_HEAT_MAX)
		{
			w.Overheat(self);
			return;
		}

		// WHERE IT ENDS -- and this trace does NO damage.
		//
		// TRF_THRUACTORS on purpose: the beam is DRAWN to the wall behind
		// whatever it is burning through, not stopped short at the first
		// monster. The damage trace below is a separate question.
		//
		// TRF_USEWEAPON is what makes it a weapon ray rather than a head
		// ray: without it P_LineTrace ignores the tracked hand and traces
		// from body yaw/pitch at eye height. TRF_ISOFFHAND only when this
		// copy is the offhand, or it would trace from the other controller.
		int trf = TRF_THRUACTORS | TRF_USEWEAPON;
		if (w.BeamSlot() == 1) trf |= TRF_ISOFFHAND;

		// player.viewheight is still needed: P_LineTrace only reaches for
		// AttackPos when OverrideAttackPosDir is set, and otherwise falls
		// through to `fromPos = t1->PosAtZ(startz)` built from this offset.
		// Drop it and that branch starts the trace at the FLOOR.
		FLineTraceData d;
		bool hit = LineTrace(angle, LNC_RANGE, pitch, trf, player.viewheight, data: d);

		bool offhand = w.BeamSlot() == 1;
		Vector3 from = offhand ? OffhandPos : AttackPos;

		// THE DIRECTION COMES FROM THE TRACE, NOT FROM A SECOND CALCULATION.
		// HitDir is the unit direction P_LineTrace actually travelled, filled
		// unconditionally. Reconstructing it independently is a bug this
		// weapon has shipped twice; the second time it drew the beam at
		// ninety degrees to the gun. Normalised defensively because "is this
		// unit length" was the unchecked assumption under both.
		Vector3 dir = d.HitDir;
		double dirLen = dir.Length();
		dir = (dirLen > 0.001) ? dir / dirLen : (0, 0, 0);

		// ON A MISS, d.HitLocation IS THE MAP ORIGIN (0,0,0), NOT "NO
		// ANSWER" -- P_LineTrace zeroes its struct and only fills the field
		// through the successful branch. Firing at open sky would otherwise
		// aim the beam at world origin.
		Vector3 to;
		if (hit)                        to = d.HitLocation;
		else if (dir dot dir > 1e-8)    to = from + dir * LNC_RANGE;
		else { w.Release(self); return; }

		// THE BEAM LEAVES THE BARREL. `from` is the controller in VR and the
		// EYE on a desktop (VRMode::SetUp's else branch sets AttackPos to
		// PosAtZ(shootz)) -- and on a desktop the gun is a screen overlay
		// with no world position, so the muzzle has to be built: eye, pushed
		// forward, right and down to where the weapon is actually drawn.
		// Plain degree trig on the body angles, which are the aim. Doom
		// convention: angle 0 is +X, 90 is +Y, positive pitch looks DOWN.
		Vector3 drawFrom;
		double hitDist = (to - from).Length();

		if (OverrideAttackPosDir)
		{
			double frac = (hitDist > 0.001)
				? clamp(w.LaserBeamOffset.Y / hitDist, 0.0, 0.5) : 0.0;
			drawFrom = from + (to - from) * frac;
		}
		else
		{
			double ca = cos(angle), sa = sin(angle);
			double cp = cos(pitch), sp = sin(pitch);
			Vector3 fwd   = (ca * cp, sa * cp, -sp);
			Vector3 right = (sa, -ca, 0);
			drawFrom = from
				+ fwd * min(LNC_MUZZLE_FWD, hitDist * 0.5)
				+ right * LNC_MUZZLE_RIGHT
				+ (0, 0, 1) * LNC_MUZZLE_UP;
		}

		// ---- shape ---------------------------------------------------------
		double charge = w.Charge();
		int band = w.Band();

		// THE GEAR CHANGE. Crossing a band is the event that matters most
		// while the trigger is down, so it gets its own punch rather than
		// relying on you noticing a colour swap in your periphery.
		if (band != w.lastBand)
		{
			if (band > w.lastBand) w.flashTics = 5;
			w.lastBand = band;
		}
		double flash = w.flashTics > 0 ? double(w.flashTics) / 5.0 : 0.0;
		if (w.flashTics > 0) w.flashTics--;

		// THE BEAM STEPS WITH THE BAND, not smoothly with heat. The damage
		// changes in gears, so the look changes in gears -- a beam that grew
		// imperceptibly would give you nothing to read, and reading it is
		// how you know when to let go. Within a band it still creeps a
		// little so it never looks frozen.
		double step = double(band);
		// Width and brightness per layer now live in DrawBeamStack, since the
		// three want different shapes rather than one scaled three ways.

		// INTENSITY STAYS UNDER 1.0 UNTIL THE TOP BAND. The fork's beam doc
		// notes the air glow feeds bloom by itself "since a core burning past
		// white is exactly what the bloom pass thresholds for". So the screen
		// only blooms out in band 5, where it is the warning rather than the
		// weapon's baseline appearance -- and for the few tics of a gear
		// change, where blowing out IS the announcement.

		// The colour IS the gauge; you read your heat off the beam without
		// looking away from what you are killing. Washed toward white for the
		// duration of a gear change.
		Color col      = LNC_Lance.LerpCol(w.CoreColor(),  0xFFFFFF, flash);
		Color innerCol = LNC_Lance.LerpCol(w.HelixColor(), 0xFFFFFF, flash);

		// NO SCENE-WIDE BEAM CALLS HERE ANY MORE.
		//
		// This used to call SetBeamCount(8, ...) and SetBeamLook(...), both of
		// which are single vec4s covering EVERY beam in the scene rather than
		// arrays. That made the Lance the de-facto owner of the whole scene's
		// beam look, and it lost that fight anyway: RS_WorldHands' grab lasers
		// force the count to 2 and rewrite the look every tic from a handler
		// that runs after the weapon, so the Lance beam was counted out of
		// existence whenever the grab lasers were on -- which is their default.
		//
		// The four slots are claimed in HoldBeams() and styled per slot there,
		// scrolling included, so nothing outside this weapon can change how the
		// Lance looks and the Lance changes nothing outside itself. The engine
		// keeps a claimed slot live regardless of SetBeamCount.
		//
		// Charge and band used to feed the scene look (air glow rose with charge,
		// taper slackened as it heated, flare stepped with the band). Those are
		// per-slot values now, and they are deliberately NOT re-applied per tic:
		// a style set once at claim time is one call a map instead of four a tic,
		// and the band already changes width, brightness, orbit and colour in
		// DrawBeamStack, which is where the weapon reads as intensifying. If the
		// owner wants the glow to climb with charge again, call
		// SetBeamStyleScroll on the three layer slots from here with the charge
		// term back in -- it is per-slot, so it is now safe to do.

		// THE THREE LAYERS -- sheath, stirred core, counter-rotating filament.
		// See DrawBeamStack for the shape and why it replaced the helix.
		//
		// PRESENT IN EVERY BAND. The owner watched a burst and asked for the
		// circular motion "for the entire firing duration", so unlike the old
		// spiral this does not wait for band 2 to appear. The bands still
		// change the beam plenty -- width, brightness, orbit radius, orbit
		// speed and the flare all step -- but the SHAPE is constant, so the
		// weapon has one identity that intensifies rather than two that swap.
		//
		// `innerCol` is the pale companion hue; the sheath takes the core
		// colour so the volume and the filament read as one object lit from
		// inside.
		w.DrawBeamStack(drawFrom, to, band, flash, col, innerCol);

		// THE VOLUMETRIC LAYER -- the air around the beam, not the beam.
		//
		// SetBeam draws a line that lights the room. SetVolumetricBeam is a
		// different system: a raymarched cone that makes the air itself glow.
		// Aimed straight down the beam with a pencil-thin cone it stops being
		// a bright line and becomes something displacing atmosphere.
		//
		// MAINHAND ONLY. Unlike the eight beam slots this is a SINGLE global
		// on the level, so two hands would overwrite each other every tic and
		// flicker. The offhand still has its own real beam in slot 1.
		//
		// DUST IS ZERO. Motes are, definitionally, points of light, and
		// points of light along the beam are the exact thing being hunted out
		// of this weapon. If it comes back it comes back as atmosphere in the
		// ROOM, never as texture on the bar.
		if (!offhand)
		{
			Vector3 vseg = to - drawFrom;
			double vlen = vseg.Length();
			if (vlen > 1.0)
			{
				level.SetVolumetricBeam(
					drawFrom, vseg / vlen, col,
					0.25 + 0.30 * charge,     // inner cone half-angle, degrees
					1.10 + 1.40 * charge,     // outer
					vlen,                     // exactly the segment
					0.28 + 0.40 * charge,     // density
					1.6,                      // falloff, tight near the lens
					0.0,                      // dust: see above
					0.045,
					0.0,
					VOLBEAM_SLOT);         // its own slot, never the flashlight's or the wheel's
			}
		}

		// Started once on the trigger edge and pitched every tic after, so
		// the approaching cook-off is audible before it is visible -- you are
		// usually looking at what you are burning, not at the beam.
		if (!w.firing)
		{
			A_StartSound("lnc/charge", CHAN_WEAPON, 0, 0.7);
			w.activeLoopChan = w.LoopChan();
			A_StartSound("lnc/loop", w.activeLoopChan, CHANF_LOOPING, 0.8, ATTN_NORM);
			w.firing = true;
		}
		A_SoundPitch(w.activeLoopChan, 0.85 + 0.55 * charge);

		// ---- the burn --------------------------------------------------
		//
		// NO SHOTS. The beam is on, and while it is on it deposits energy at
		// a rate. The rate is accumulated as a real number and spent when it
		// builds a whole point, so the fiction is continuous and only the
		// bookkeeping is not.
		//
		// A SECOND TRACE, without TRF_THRUACTORS, so it stops at the first
		// thing in the way -- the drawing trace above deliberately passes
		// through actors to reach the wall behind them, which is right for
		// the picture and wrong for the damage.
		int dtrf = TRF_USEWEAPON;
		if (offhand) dtrf |= TRF_ISOFFHAND;
		FLineTraceData hitData;
		LineTrace(angle, LNC_RANGE, pitch, dtrf, player.viewheight, data: hitData);

		Actor victim = hitData.HitActor;
		if (!victim || !victim.bShootable)
		{
			// Nothing in the beam. Drop the remainder rather than banking it,
			// or sweeping onto a target would hand it a stored-up lump.
			w.burn = 0;
			return;
		}

		w.burn += w.DPS() / 35.0;

		// THE COOK, accumulated at the RATE rather than in whole points, so
		// the glow swells smoothly instead of stepping each time a damage
		// point happens to land. Sweeping onto a new target starts it from
		// cold rather than handing it the last one's progress.
		if (w.cookTarget != victim)
		{
			w.cookTarget = victim;
			w.cookAmt = 0.0;
		}
		w.cookAmt += w.DPS() / 35.0;
		w.DrawCookGlow(hitData.HitLocation, victim);

		int whole = int(w.burn);
		if (whole <= 0) return;
		w.burn -= whole;

		// DMG_NO_PAIN, or a held beam pins a monster in its pain state
		// permanently and it never acts again -- which trivialises every
		// fight and looks broken besides. It still bleeds and still dies.
		// INFLICTOR IS THE WEAPON'S MARKER, SOURCE IS THE PLAYER. GunBonsai
		// reads inflictor.master to work out which hand earned the XP; the
		// player stays the source so kill credit, infighting and the burn
		// handler's own "did a Lance kill this" test all still resolve to
		// the shooter.
		let tg = w.GetTag(self);
		victim.DamageMobj(tg ? Actor(tg) : self, self, whole, 'Hitscan', DMG_NO_PAIN);

		if (Random(0, 11) == 0)
			A_StartSound("lnc/sizzle", CHAN_AUTO, CHANF_DEFAULT, 0.3);
	}

	// Trigger released, or the state machine left Fire. Put the beam away.
	action void A_LanceStop()
	{
		let w = LNC_Lance(invoker);
		if (!w) return;
		w.Release(self);
	}

	// Releases only THIS hand's slot rather than calling ClearBeams, or
	// firing the mainhand would blink the offhand's beam out every tic.
	void Release(Actor who)
	{
		if (firing)
		{
			// THE CHANNEL THE LOOP WAS STARTED ON, not the one this hand would
			// choose now. Stopping a different channel than the loop was started
			// on leaves it running forever.
			if (who) who.A_StopSound(activeLoopChan);
			firing = false;
		}
		// All three of this hand's layers. The count stays at 6 once
		// anything has fired, so a slot left holding real endpoints would go
		// on being drawn after the trigger came up.
		ClearBeams();

		// The volumetric layer is a single global with no slot to zero, so it
		// must be switched off explicitly -- and only by the hand that
		// claimed it, or the offhand releasing would kill the mainhand's.
		if (BeamSlot() == 0)
			level.ClearVolumetricBeam(VOLBEAM_SLOT);

		// Heat is NOT reset. That is the whole pulse-fire technique: the band
		// you climbed to survives the release and only bleeds off with time.
		burn = 0;
	}

	void Overheat(Actor who)
	{
		Release(who);
		heat = LNC_HEAT_MAX;
		lockTics = LNC_LOCKOUT;
		if (who) who.A_StartSound("lnc/cookoff", CHAN_WEAPON, 0, 1.0);
	}

	// COOK-OFF IS A FLAT FIVE SECONDS AND THEN STONE COLD, rather than a
	// slow bleed down from 100. A bleed would let you cook off and go
	// straight back to band 4, which makes overheating nearly free; a hard
	// reset means the mistake costs you the entire climb as well as the five
	// seconds.
	//
	// Ordinary cooling is half the rise rate -- 8 seconds from full -- so
	// short bursts cost almost nothing and long holds genuinely commit.
	//
	// COUNTED IN DoEffect so it runs whether or not the weapon is selected.
	// Switching to your other hand while this one cools is intended (that is
	// the two-hand rhythm), but switching AWAY must not pause the timer, or
	// the lockout would be free.
	override void DoEffect()
	{
		Super.DoEffect();

		// ---- THE WORLD PROP DRAWS THE GUN NOW ------------------------------
		//
		// When lnc_world is on, an actor on the controller draws the lance and
		// this layer must draw NOTHING, or there are two of them -- one in the
		// room and one glued to your view.
		//
		// THE LAYER STAYS. It still runs every state: ready, the beam, the
		// overheat, the cooldown, the tier bands and every SetBeam call are all
		// this state machine, and the prop only copies the sprite and frame it
		// lands on. Killing the layer would kill the weapon; making it invisible
		// is the whole change.
		//
		// bNODRAW rather than parking it on TNT1, because the SPRITE and FRAME
		// are what the prop reads -- PLSC vs PLSF is how it tells ready from
		// overheated. A TNT1 state would report TNT1 A for everything and the
		// gun would freeze on one pose.
		if (owner && owner.player)
		{
			let psp = owner.player.FindPSprite(
				bOffhandWeapon ? PSP_OFFHANDWEAPON : PSP_WEAPON);
			if (psp)
			{
				let c = CVar.GetCVar("lnc_world", owner.player);
				// NoDraw, NOT bNODRAW. PSprite's field is a plain native bool
				// (player.zs:3364) and has no b-prefixed flag twin, so `bNODRAW`
				// was an unknown identifier and it failed the WHOLE file -- which
				// is why RS_Lance has not compiled in some time and why it is not
				// in the owner's load order. Found 2026-10-01 while verifying the
				// beam claim change; not in CODER_PLAN.
				psp.NoDraw = (c && c.GetBool());
			}
		}

		// SAFETY: the beam lives in a level-global slot, so anything that
		// ends a trigger pull without running the Beam state's exit -- dying
		// mid-burst, a forced swap, a telefrag -- would leave a live segment
		// hanging in the world with a looping sound under it. The state
		// machine cannot cover those; DoEffect runs regardless.
		if (firing && owner)
		{
			bool stillUp = owner.health > 0 && owner.player
				&& (owner.player.ReadyWeapon == self
					|| owner.player.OffhandWeapon == self);
			if (!stillUp) Release(owner);
		}

		// THE COUNTER. See the Default block for why heat is an ammo type at
		// all: it means every status bar, alt-HUD and third-party HUD ever
		// written already knows how to display it.
		//
		// ONLY THE READY WEAPON WRITES IT. The HUD prints the ready weapon's
		// ammo and the two hands hold separate heat, so if both wrote, the
		// number would flicker between two pools. The mainhand owns it; the
		// offhand's heat is read off its beam colour like everything else.
		//
		// CLAMPED TO 99, NOT 100. Cook-off happens AT 100, so a counter able
		// to show it would be displaying a number you can never fire at. 99
		// is the last value that still means "you may pull the trigger", and
		// the overheat state says the rest -- which is also why the readout
		// sits at 99 for the whole lockout rather than counting anything.
		if (owner && owner.player && owner.player.ReadyWeapon == self)
		{
			let h = owner.FindInventory("LNC_Heat");
			if (!h)
			{
				owner.A_GiveInventory("LNC_Heat", 1);
				h = owner.FindInventory("LNC_Heat");
			}
			if (h) h.Amount = min(HeatPercent(), 99);
		}

		if (lockTics > 0)
		{
			lockTics--;
			heat = LNC_HEAT_MAX;              // pinned, and the HUD should say so
			if (lockTics <= 0) heat = 0.0;    // then all the way back
			return;
		}

		// GRACE FIRST, THEN FALL. graceLeft is refilled every tic the beam is
		// live, so it only starts counting down once the trigger is actually
		// up -- which means a burst-pause-burst rhythm keeps its rung, and
		// walking away from the fight loses it.
		if (firing)
		{
			graceLeft = LNC_HEAT_GRACE;
		}
		else if (graceLeft > 0)
		{
			graceLeft--;
		}
		else if (heat > 0.0)
		{
			heat = max(0.0, heat - LNC_HEAT_FALL / 35.0);
			if (heat <= 0.0) lastBand = 0;
		}
	}

	static Color LerpCol(int a, int b, double t)
	{
		t = clamp(t, 0.0, 1.0);
		int ar = (a >> 16) & 255, ag = (a >> 8) & 255, ab = a & 255;
		int br = (b >> 16) & 255, bg = (b >> 8) & 255, bb = b & 255;
		return Color(255,
			int(ar + (br - ar) * t),
			int(ag + (bg - ag) * t),
			int(ab + (bb - ab) * t));
	}

	States
	{
	Spawn:
		PLAS A -1;
		Stop;

	Ready:
		PLSC A 1 A_WeaponReady(WRF_NOSECONDARY);
		Loop;

	Deselect:
		TNT1 A 0 A_LanceStop();
		PLSC A 1 A_Lower;
		Loop;

	Select:
		PLSC A 1 A_Raise;
		Loop;

	// No ammo check. Heat is the only gate.
	Fire:
		TNT1 A 0 A_JumpIf(invoker.lockTics > 0, "Overheated");
		Goto Beam;

	// ONE TIC PER LOOP. The beam is re-traced and re-drawn every tic, which
	// is what makes it track as you turn rather than lagging behind the
	// crosshair like a spawned object would.
	Beam:
		PLSF A 1 Bright A_LanceBeam();
		TNT1 A 0 A_ReFire("Beam");
		TNT1 A 0 A_LanceStop();
		Goto Ready;

	// SHORTER THAN THE LOCKOUT, DELIBERATELY -- 28 tics against 175. Holding
	// the trigger through a cook-off cycles this rather than sitting in one
	// long uninterruptible pose, so the gun returns to Ready often enough to
	// be DESELECTED. The punishment is "you have no beam", not "you have no
	// inputs" -- and swapping to your other hand while this one cools is the
	// intended answer, not an exploit.
	Overheated:
		TNT1 A 0 A_LanceStop();
		TNT1 A 0 A_StartSound("lnc/empty", CHAN_AUTO, 0, 0.6);
		PLSC C 28;
		Goto Ready;
	}
}

// =====================================================================
// LNC_Heat -- the heat gauge, wearing an ammo type's clothes.
//
// NOTHING EVER SPENDS THIS. AmmoUse is 0 and AMMO_OPTIONAL lets the Lance
// fire at zero, so this is not a resource -- it is a display. LNC_Lance's
// DoEffect assigns Amount straight from HeatPercent() every tic.
//
// WHY AN AMMO TYPE RATHER THAN A HUD ELEMENT. A custom readout means drawing
// it, which means owning a position, a font and a scale on the status bar,
// the alt-HUD, the fullscreen HUD and whatever HUD the player has actually
// installed -- and being wrong on three of them. Every one of those already
// knows how to print the ready weapon's ammo. Borrowing that costs one class
// and one line a tic, and it is correct everywhere by construction.
//
// MaxAmount 99: cook-off is at 100, so 99 is the highest number you can
// still fire at. See DoEffect for the argument.
//
// UNDROPPABLE and UNTOSSABLE so it can never be thrown away, and
// IGNORESKILL so a skill's ammo multiplier does not scale a temperature.
class LNC_Heat : Ammo
{
	Default
	{
		Inventory.Amount 0;
		Inventory.MaxAmount 99;
		Ammo.BackpackAmount 0;
		Ammo.BackpackMaxAmount 99;
		Inventory.Icon "";
		Tag "Heat";
		+INVENTORY.UNDROPPABLE
		+INVENTORY.UNTOSSABLE
		+INVENTORY.IGNORESKILL
	}
}


// The offhand copy. Same weapon; the flag is what puts it in the other hand,
// which in turn is what BeamSlot() reads to claim beam slot 1. Its heat is
// its own -- alternating hands so one cools while the other burns is the
// intended rhythm of dual-wielding these.
class LNC_LanceOffhand : LNC_Lance
{
	Default
	{
		Tag "Lance (offhand)";
		Weapon.SelectionOrder 1079;
		+WEAPON.OFFHANDWEAPON;
	}
}


// =====================================================================
// LNC_LaserMarine -- the class that starts with both.
//
// TWO LANCES, ONE PER HAND, FROM THE FIRST TIC. This was one gun with the
// second held back as the first core's reward, and that was the wrong thing
// to charge for: it made the opening map a slog at half damage, waiting on a
// drop, to buy a spike that was never really in doubt. The guns are the
// weapon -- start holding the weapon.
//
// WHAT CORES BUY NOW IS TIER, which is the rate both guns fire at, and they
// arrive on a curve that starts generous and tightens (LNC_DropHandler).
// That puts the progression in the thing you feel every second you hold the
// trigger, rather than in a one-off unlock.
//
// A PLAYER CLASS RATHER THAN AN UNCONDITIONAL GRANT. This used to be an
// event handler that gave every player a Lance on spawn regardless of who
// they were, which was fine while this pk3 was a test bed and wrong the
// moment it became something you load alongside a real mod: it armed every
// class in the game with a weapon they did not choose.
//
// Now it is a choice. Pick Laser Marine and you start with it; pick
// anything else and you can still FIND one, because LNC_LanceCore already
// arms a player who has no Lance at all. Same item, two ways in.
//
// GiveDefaultInventory RATHER THAN Player.StartItem, because the Lance has
// no ammo type at all -- and GiveDefaultInventory only auto-selects weapons
// that have ammo, so a StartItem Lance would be granted and then left
// unequipped behind the pistol. Seating PendingWeapon by hand is the only
// reliable way to actually be holding it.
// =====================================================================
class LNC_LaserMarine : DoomPlayer
{
	Default
	{
		Player.DisplayName "Laser Marine";
	}

	override void GiveDefaultInventory()
	{
		Super.GiveDefaultInventory();

		// A LANCE IN EACH HAND, FROM THE FIRST TIC.
		//
		// Dual wield used to be the unlock the first core bought. It is the
		// starting kit now: the guns are the weapon, and spending the opening
		// map at half the damage waiting on a 2% drop was paying for a spike
		// that had already been decided. Cores still exist and still matter --
		// they buy tier, which is the rate both guns fire at.
		//
		// Both seated explicitly. Player.StartItem cannot do this job: it only
		// auto-selects weapons that HAVE ammo, and none of these has an ammo
		// type at all, so they would be granted and then left sitting
		// unequipped behind the pistol.
		//
		// Their beams do not collide -- the Lances draw in slots 0-5 with
		// their cook glows in 6-7, and both ask for the same frame-global
		// beam count.
		A_GiveInventory("LNC_Lance", 1);
		A_GiveInventory("LNC_LanceOffhand", 1);
		if (CountInv("LNC_LanceTier") < 1)
			A_GiveInventory("LNC_LanceTier", 1);

		let w = Weapon(FindInventory("LNC_Lance"));
		if (w && player) player.PendingWeapon = w;

		let off = Weapon(FindInventory("LNC_LanceOffhand"));
		if (off && player) player.OffhandWeapon = off;
	}
}
