import { describe, it, expect, vi, afterEach } from 'vitest'
import {
  isGearIncludedCourse, gearPackList, gearSlot, gearAlternatives,
  defaultRentalItems, toggleGearSelection, FULL_GEAR_SET, GEAR_ITEMS,
  GEAR_ALACARTE_PRICES, HAS_GEAR_ALTERNATIVES, RENTAL_GEAR_ITEMS,
  HAS_RENTAL_GEAR_ALTERNATIVES, HAS_OWNED_ONLY_GEAR,
  gearOwnGroups, gearBaseLabel, gearStyleLabel, ownedInSlot,
} from './gear'
import type { Booking } from '../types/database'

const bookingWith = (gear: unknown): Booking =>
  ({ details: { gear } } as unknown as Booking)

const RUBBER = 'Boots (rubber sole)'
const FELT   = 'Boots (felt sole)'

describe('gearPackList', () => {
  it('packs nothing for a diver on their own gear', () => {
    expect(gearPackList(bookingWith({ rent: false }))).toEqual({ summary: 'Own gear', items: [] })
    expect(gearPackList(bookingWith(undefined))).toEqual({ summary: 'Own gear', items: [] })
  })

  it('packs a full set for course-included gear', () => {
    const out = gearPackList(bookingWith({ rent: false, included: true }))
    expect(out.summary).toBe('Included with course')
    expect(out.items).toContain('BCD')
    expect(out.items).toContain('Dive computer')
  })

  it('packs one boot style for course-included gear, not both', () => {
    const out = gearPackList(bookingWith({ rent: false, included: true }))
    expect(out.items).toContain(RUBBER)
    expect(out.items).not.toContain(FELT)
  })

  it('surfaces the assistance note and packs nothing yet', () => {
    const out = gearPackList(bookingWith({ rent: false, assistance_note: 'unsure on fins' }))
    expect(out).toEqual({ summary: 'Needs help', items: [], note: 'unsure on fins' })
  })

  it('packs exactly the à-la-carte items', () => {
    const out = gearPackList(bookingWith({ rent: true, items: ['BCD', 'Fins'] }))
    expect(out.summary).toBe('À-la-carte (2)')
    expect(out.items).toEqual(['BCD', 'Fins'])
  })
})

describe('isGearIncludedCourse', () => {
  it('treats Open Water courses as gear-included', () => {
    expect(isGearIncludedCourse('Open Water Course')).toBe(true)
    expect(isGearIncludedCourse('PADI Open Water Course')).toBe(true)
    expect(isGearIncludedCourse('open water')).toBe(true)
  })

  it('treats Discover Scuba / DSD / Try Dive as gear-included', () => {
    expect(isGearIncludedCourse('Discover Scuba Diving')).toBe(true)
    expect(isGearIncludedCourse('DSD')).toBe(true)
    expect(isGearIncludedCourse('Try Dive')).toBe(true)
  })

  it('treats EFR (dry first-aid course) as gear-included', () => {
    expect(isGearIncludedCourse('EFR Course')).toBe(true)
    expect(isGearIncludedCourse('Emergency First Response')).toBe(true)
  })

  it('does NOT bundle gear for Advanced Open Water', () => {
    expect(isGearIncludedCourse('Advanced Open Water')).toBe(false)
    expect(isGearIncludedCourse('PADI Advanced Open Water Course')).toBe(false)
  })

  it('does NOT bundle gear for other continuing-ed courses', () => {
    expect(isGearIncludedCourse('EANx / Nitrox Course')).toBe(false)
    expect(isGearIncludedCourse('Deep Specialty')).toBe(false)
    expect(isGearIncludedCourse('PADI Rescue Course')).toBe(false)
    expect(isGearIncludedCourse('Equipment Course')).toBe(false)
  })

  it('handles null / empty titles', () => {
    expect(isGearIncludedCourse(null)).toBe(false)
    expect(isGearIncludedCourse(undefined)).toBe(false)
    expect(isGearIncludedCourse('')).toBe(false)
  })
})

describe('the shipped catalog', () => {
  it('offers both boot styles, each with its own price', () => {
    expect(GEAR_ITEMS).toContain(RUBBER)
    expect(GEAR_ITEMS).toContain(FELT)
    expect(GEAR_ALACARTE_PRICES[RUBBER]).toBeTypeOf('number')
    expect(GEAR_ALACARTE_PRICES[FELT]).toBeTypeOf('number')
  })

  it('prices every item it lists', () => {
    for (const item of GEAR_ITEMS) {
      expect(GEAR_ALACARTE_PRICES[item], `${item} has no price`).toBeTypeOf('number')
    }
  })

  it('reports that it has alternatives, which is what shows the hint', () => {
    expect(HAS_GEAR_ALTERNATIVES).toBe(true)
  })

  // The starter catalog rents everything it lists. A shop that stocks a style
  // for divers to own but not to borrow drops it from gearPrices — see the
  // owned-only suite below for what that changes.
  it('rents everything it lists, so nothing is owned-only', () => {
    expect(RENTAL_GEAR_ITEMS).toEqual(GEAR_ITEMS)
    expect(HAS_OWNED_ONLY_GEAR).toBe(false)
    expect(HAS_RENTAL_GEAR_ALTERNATIVES).toBe(true)
  })
})

describe('gearSlot', () => {
  it('reads the two boot styles as one slot on the diver', () => {
    expect(gearSlot(RUBBER)).toBe('boots')
    expect(gearSlot(FELT)).toBe('boots')
  })

  it('leaves an unqualified item as its own slot', () => {
    expect(gearSlot('BCD')).toBe('bcd')
    expect(gearSlot('Dive computer')).toBe('dive computer')
  })

  it('only strips a trailing qualifier, not a parenthesis mid-name', () => {
    expect(gearSlot('Mask (low volume)')).toBe('mask')
    expect(gearSlot('Wetsuit (5mm) hooded')).toBe('wetsuit (5mm) hooded')
  })

  it('keeps distinct items distinct', () => {
    expect(gearSlot('Fins')).not.toBe(gearSlot('Mask'))
  })
})

describe('gearAlternatives', () => {
  it('pairs the two boot styles with each other', () => {
    expect(gearAlternatives(RUBBER)).toEqual([FELT])
    expect(gearAlternatives(FELT)).toEqual([RUBBER])
  })

  it('finds none for an item the shop offers in one style', () => {
    expect(gearAlternatives('BCD')).toEqual([])
    expect(gearAlternatives('Regulator')).toEqual([])
  })

  it('never lists the item itself', () => {
    for (const item of GEAR_ITEMS) {
      expect(gearAlternatives(item)).not.toContain(item)
    }
  })
})

describe('gearOwnGroups', () => {
  it('folds the boot styles into one row with both styles to choose from', () => {
    const boots = gearOwnGroups().find(g => g.label === 'Boots')
    expect(boots).toEqual({ items: [RUBBER, FELT], label: 'Boots', styles: ['rubber sole', 'felt sole'] })
  })

  it('leaves a single-style item as its own row, styles empty', () => {
    const bcd = gearOwnGroups().find(g => g.label === 'BCD')
    expect(bcd).toEqual({ items: ['BCD'], label: 'BCD', styles: [] })
  })

  it('covers the whole catalog exactly once, in catalog order', () => {
    expect(gearOwnGroups().flatMap(g => g.items)).toEqual(GEAR_ITEMS)
  })

  it('keeps a lone qualified item spelled out rather than shortening it', () => {
    expect(gearOwnGroups(['Mask (low volume)'])).toEqual([
      { items: ['Mask (low volume)'], label: 'Mask (low volume)', styles: [] },
    ])
  })

  it('reads an unqualified entry as a style of its own name', () => {
    const groups = gearOwnGroups(['Boots', 'Boots (felt sole)'])
    expect(groups).toEqual([
      { items: ['Boots', 'Boots (felt sole)'], label: 'Boots', styles: ['Boots', 'felt sole'] },
    ])
  })
})

describe('gearBaseLabel / gearStyleLabel', () => {
  it('splits a styled item into the name a checkbox reads and the style beside it', () => {
    expect(gearBaseLabel(FELT)).toBe('Boots')
    expect(gearStyleLabel(FELT)).toBe('felt sole')
  })

  it('leaves an unstyled item whole', () => {
    expect(gearBaseLabel('Dive computer')).toBe('Dive computer')
    expect(gearStyleLabel('Dive computer')).toBeNull()
  })

  it('keeps the catalog\'s own casing, unlike the slot key', () => {
    expect(gearBaseLabel(RUBBER)).toBe('Boots')
    expect(gearSlot(RUBBER)).toBe('boots')
  })
})

describe('ownedInSlot', () => {
  it('lists what the diver owns in a slot, in catalog order', () => {
    expect(ownedInSlot([FELT, 'BCD', RUBBER], [RUBBER, FELT])).toEqual([RUBBER, FELT])
    expect(ownedInSlot(['BCD'], [RUBBER, FELT])).toEqual([])
  })
})

describe('defaultRentalItems', () => {
  it('ticks one boot style, not both, for a diver who owns nothing', () => {
    const items = defaultRentalItems([])
    expect(items.filter(i => gearSlot(i) === 'boots')).toEqual([RUBBER])
  })

  it('still ticks everything else the diver does not own', () => {
    const items = defaultRentalItems([])
    expect(items).toContain('BCD')
    expect(items).toContain('Regulator')
    expect(items).toContain('Dive computer')
  })

  it('drops the boots slot entirely for a diver who owns felt-soled ones', () => {
    const items = defaultRentalItems([FELT])
    expect(items.some(i => gearSlot(i) === 'boots')).toBe(false)
    expect(items).toContain('BCD')
  })

  it('drops it for a diver who owns rubber-soled ones too', () => {
    expect(defaultRentalItems([RUBBER]).some(i => gearSlot(i) === 'boots')).toBe(false)
  })

  it('excludes every other item the diver owns, by exact name', () => {
    const items = defaultRentalItems(['BCD', 'Mask'])
    expect(items).not.toContain('BCD')
    expect(items).not.toContain('Mask')
    expect(items).toContain('Fins')
  })

  it('ignores owned gear the catalog no longer lists', () => {
    const items = defaultRentalItems(['Rebreather'])
    expect(items).toEqual(defaultRentalItems([]))
  })

  it('handles a null / undefined profile field', () => {
    expect(defaultRentalItems(null)).toEqual(defaultRentalItems([]))
    expect(defaultRentalItems(undefined)).toEqual(defaultRentalItems([]))
  })

  it('is what FULL_GEAR_SET is: one of every slot', () => {
    expect(FULL_GEAR_SET).toEqual(defaultRentalItems([]))
    expect(FULL_GEAR_SET.length).toBe(GEAR_ITEMS.length - 1)
  })
})

describe('toggleGearSelection', () => {
  it('adds an item that is not selected', () => {
    expect(toggleGearSelection(['BCD'], 'Mask')).toEqual(['BCD', 'Mask'])
  })

  it('removes an item that is selected', () => {
    expect(toggleGearSelection(['BCD', 'Mask'], 'BCD')).toEqual(['Mask'])
  })

  it('swaps boot styles rather than stacking them', () => {
    expect(toggleGearSelection(['BCD', RUBBER], FELT)).toEqual(['BCD', FELT])
    expect(toggleGearSelection(['BCD', FELT], RUBBER)).toEqual(['BCD', RUBBER])
  })

  it('leaves the diver with no boots when they untick the one they had', () => {
    expect(toggleGearSelection([RUBBER], RUBBER)).toEqual([])
  })

  it('does not disturb unrelated items when swapping styles', () => {
    const out = toggleGearSelection(['Regulator', RUBBER, 'Mask'], FELT)
    expect(out).toContain('Regulator')
    expect(out).toContain('Mask')
    expect(out.filter(i => gearSlot(i) === 'boots')).toEqual([FELT])
  })

  it('is a no-op on the second toggle back', () => {
    const once = toggleGearSelection(['BCD'], FELT)
    expect(toggleGearSelection(once, FELT)).toEqual(['BCD'])
  })
})

// A shop can stock a style for divers to own without renting it: leave it out
// of gearPrices and it stays on the profile checklist but never on the rental
// one. The starter catalog rents everything it lists, so load the module
// against a catalog that doesn't.
describe('a catalog with owned-only gear', () => {
  const ITEMS = ['BCD', 'Mask', RUBBER, FELT]
  const PRICES: Record<string, number> = { BCD: 15, Mask: 5, [FELT]: 3 }

  const loadGear = async () => {
    vi.resetModules()
    vi.doMock('../config/site', () => ({
      siteConfig: { business: { gearItems: ITEMS, gearPrices: PRICES } },
    }))
    return await import('./gear')
  }

  afterEach(() => {
    vi.doUnmock('../config/site')
    vi.resetModules()
  })

  it('rents the priced items and nothing else', async () => {
    const gear = await loadGear()
    expect(gear.RENTAL_GEAR_ITEMS).toEqual(['BCD', 'Mask', FELT])
    expect(gear.HAS_OWNED_ONLY_GEAR).toBe(true)
  })

  it('keeps the owned-only style in the catalog a diver describes themselves with', async () => {
    const gear = await loadGear()
    expect(gear.GEAR_ITEMS).toContain(RUBBER)
    expect(gear.HAS_GEAR_ALTERNATIVES).toBe(true)
    // Nothing to swap between on the rental side, so no hint about it.
    expect(gear.HAS_RENTAL_GEAR_ALTERNATIVES).toBe(false)
  })

  it('never ticks it by default, and reads owning it as a filled slot', async () => {
    const gear = await loadGear()
    expect(gear.defaultRentalItems([])).toEqual(['BCD', 'Mask', FELT])
    expect(gear.defaultRentalItems([RUBBER])).toEqual(['BCD', 'Mask'])
    expect(gear.FULL_GEAR_SET).not.toContain(RUBBER)
  })

  it('clears a carried-in selection of it, which no checkbox can untick', async () => {
    const gear = await loadGear()
    expect(gear.toggleGearSelection(['BCD', RUBBER], FELT)).toEqual(['BCD', FELT])
  })
})
