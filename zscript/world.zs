// ============================================================================
// THE LANCE AS A THING IN THE ROOM.
//
// It was a player sprite: drawn after the world is finished and glued to your
// view. That slot cannot be occluded by a doorframe, cannot take room light,
// and cannot be seen by another player -- and for a weapon whose whole read is
// a beam coming out of it, the last one matters most. In netplay you want to
// see where someone else's lance is pointing.
//
// ------------------------------------------------------------ WHAT CHANGED
//
// Only where it is DRAWN. The weapon keeps its states, its slot, its heat, its
// tiers and its entire beam machinery -- a world actor per hand rides the
// controller and copies the frame the weapon's state machine lands on.
//
// This is the same shape RS_TestPistol and RS_ShieldSaw use, deliberately: a
// third way of doing it would be a third thing to debug.
//
// ------------------------------------------------------------- THE BEAM
//
// Unaffected, and worth saying because it is the obvious guess. The beam is
// already anchored to the hand and resolved at DRAW rate -- see
// SetBeamAnchor in lance.zs -- so it does not care whether the gun beside it
// is a psprite or an actor. The two were mismatched before that fix, not
// because of this one.
// ============================================================================

class LNC_LanceProp : Actor
{
	Default
	{
		+NOGRAVITY; +NOBLOCKMAP; +NOINTERACTION; +DONTSPLASH;
		+NOTONAUTOMAP;
		Radius 1; Height 1;
		RenderStyle "Normal";
	}

	States
	{
	Spawn:
		PLSC A -1;
		Stop;
	}
}

class LNC_LancePropOff : LNC_LanceProp {}


class LNC_LanceWorld : EventHandler
{
	private Actor prop[2];
	private bool  warned;

	override void WorldTick()
	{
		let p = players[consoleplayer];
		if (!p || !p.mo) return;
		let pmo = PlayerPawn(p.mo);
		if (!pmo) return;

		for (int h = 0; h < 2; ++h)
		{
			let w = (h == 0) ? p.ReadyWeapon : p.OffhandWeapon;
			bool want = w && (w is 'LNC_Lance') && Flag("lnc_world", true);

			if (!want)
			{
				if (prop[h]) { prop[h].Destroy(); prop[h] = null; }
				continue;
			}

			if (!prop[h])
			{
				String cls = (h == 0) ? "LNC_LanceProp" : "LNC_LancePropOff";
				prop[h] = Actor.Spawn(cls, pmo.Pos, NO_REPLACE);
				if (!prop[h])
				{
					if (!warned)
					{
						warned = true;
						Console.Printf("\c[Red]RS_Lance: could not spawn the world prop");
					}
					continue;
				}
			}

			// THE PLAYSIM POSITION IS THE HAND; the DRAWN position is the
			// controller's frame -- see FollowMainHand in MODELDEF. Both,
			// because the renderer wants the frame and everything else wants the
			// actor somewhere sensible: culling, sound origins, and anything
			// asking how far away it is.
			prop[h].SetOrigin((h == 0) ? pmo.AttackPos : pmo.OffhandPos, true);

			// THE WEAPON'S OWN ANIMATION, COPIED ACROSS.
			//
			// PLSC A/B/C and PLSF A/B are the frames the state machine already
			// drives -- ready, overheated, firing. Read off the psprite rather
			// than duplicated here, so heat, tiers and the beam stay in one
			// place and this file never has to know what a tier is.
			let psp = p.FindPSprite((h == 0) ? PSP_WEAPON : PSP_OFFHANDWEAPON);
			if (psp && psp.CurState)
			{
				// THE FRAME AND THE SPRITE. PLSC and PLSF are different sprite
				// handles mapped to different mesh frames, so copying the frame
				// letter alone would draw PLSF's frame index against PLSC's
				// table -- the overheat pose showing as a ready pose.
				prop[h].sprite = psp.CurState.sprite;
				prop[h].frame  = psp.CurState.frame;
			}
		}
	}

	override void WorldUnloaded(WorldEvent e)
	{
		for (int h = 0; h < 2; ++h)
			if (prop[h]) { prop[h].Destroy(); prop[h] = null; }
	}

	private static bool Flag(String n, bool d)
	{
		let c = CVar.GetCVar(n, players[consoleplayer]);
		return c ? c.GetBool() : d;
	}
}
