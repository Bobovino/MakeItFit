# Lore — Design Doc

Status: **settled premise, open details.** Unlike the other two design docs, nothing here blocks
code. Its job is to keep the fiction consistent with mechanics that mostly already exist, and to
be the source for player-facing copy (Steam description, tenant text, shop strings).

The governing rule: **the fiction exists to justify mechanics that were designed first.** Where
the two conflict, the mechanic wins and the fiction gets rewritten. Several earlier premises were
discarded for being more elaborate than anything the game actually does.

## 1. The premise

In the near future, housing has become so expensive that the only realistic way to get a home is
to win one in a YouTuber's giveaway.

To relieve the crisis, the newly created **Housing Office** has decreed that the lowest rents be
reduced — by fax, to a more manageable size.

You are the technician who has to make the results habitable.

### 1.1 The pun, and why it does not translate

The Spanish phrasing carries the whole joke: **"reducir las rentas más bajas"** means both *lower
the cheapest rents* — an ordinary housing policy — and *shrink the poorest people*, because in
Spanish `las rentas bajas` idiomatically means low-income households. Four words containing the
entire premise.

**English has no equivalent noun**, so a direct translation loses it. The fix is to move the pun
onto the verb, which English does carry: *"the Housing Office has decreed that the lowest earners
be reduced."* `Reduce` means both *cut* and *make smaller*.

Any localisation needs this checked per language rather than translated literally. It is the one
line in the game where the wording is load-bearing.

## 2. Why a fax

The apparatus is a fax machine. This is not decoration — it justifies three mechanics that were
designed independently and previously had no fictional explanation:

**Weight is conserved across scales.** A fax transmits *information*, and mass is not information.
A sofa sent down arrives reconstituted at a seventh of its size still carrying its original mass.
This is exactly the rule in `design_recursive_apartments.md` §6, where a hand-me-down from the
parent apartment arrives as a permanent, unmovable obstruction — invented for mechanical reasons,
and now explained without strain.

**Every level down is degraded.** Each fax is a lossier copy than its original: grain, lost
contrast, dropped lines. That is the per-depth degradation the coupling systems already apply —
less light, inherited noise, a smaller budget — and it is the `k < 1` that makes the recursive
economy's geometric series converge (§5.6). Each sublet is poorer than the one above it because
each copy is worse than its original.

**Recursion is legible in one image.** Faxing your own address needs no explanation: it is the
camera pointed at its own monitor. Everyone has seen that effect, knows it repeats inward, and
knows each iteration is blurrier. The mechanic and its termination arrive in the same picture.

Fax also fits the register better than a shrink ray would: obsolete administrative technology
rather than science fiction, which keeps the comedy deadpan and bureaucratic. And it is
universally recognised, which matters now that the setting is no longer tied to one country.

## 3. Transfer, not copy — except when it loops

**Decided: the fax transfers.** The machine consumes the original. This is the clean default and
raises no awkward questions in the ordinary case.

**Duplication is the exception, and it is not random.** The machine duplicates when the
destination is the origin — faxing to your own address gives it nowhere to transfer *to*, so it
copies instead.

This unifies two things that would otherwise be unrelated oddities: **the duplication bug and
recursion are the same phenomenon.** It also populates a recursive apartment with progressively
grainier copies of the same person, which is both the mechanic and the horror of it.

Open: whether the player can ever *cause* a duplication deliberately, and whether duplicates
become tenants who must themselves be housed. Both are attractive and neither is needed for v1.

## 4. The player

**Habitability Technician**, working for the Housing Office.

Not *architect* — too prestigious, and it implies creative freedom the game does not grant.
Not *interior designer* — implies taste and decoration, where the game is about compliance and
fit. The job title should sound official and slightly boring, because the joke is that somebody
has to certify that a person fits in a drawer.

Alternatives considered, kept in case the shorter one wears better in UI: *Space Optimiser*
(more corporate-dystopian, slightly generic), *Dwelling Certifier* (emphasises that your signature
is what makes the result legal), *Adjuster* (short, nice double meaning, reads as insurance).

Whatever is chosen must be **short** — it appears in the HUD, in tenant dialogue and in shop
strings, not only in the store description.

## 5. Tone — the mechanic is the metaphor

The strongest fiction in this game is not the premise but the **per-level metaphor**: a mechanic
that means something about the people living in it. This came out of an explicit decision that
levels should be *about* something rather than justified by physics.

Worked examples:

- **The couple who cannot be big at the same time** — when one opens the door, they open up, and
  become full-size; the other shrinks. They swap between the box and the apartment constantly.
  Two Moments, and the exchange is forced.
- **Mother and daughter** — the daughter's room is the same apartment, smaller, and the mother
  grew up in that same layout. Whatever is placed above appears below, because you raise a child
  the way you were raised. The fixed-point requirement becomes: find an arrangement that survives
  being handed down. Under the fax premise this sharpens — each generation is a copy of a copy.
- **The one who never goes out** — a looping flat. He leaves for work each morning and comes back
  in through the other door. The plan shows separate rooms; the zones merge into one.
- **The widow and the piano** — furniture that collides with its own tail in a looped room. Either
  the piano goes or she does.

### 5.1 The theme this reveals

Sorting the level brainstorm surfaced a pattern worth naming: an unusually large share of the
ideas are about **people whose housing forces them to become invisible**. Hikikomori; hiding
things from each other; the couple who officially do not live together; overprotective parents
controlling who comes and goes; the sleepwalker; the invisible friend; the foster room;
parentification; the separated couple who cannot afford to move out.

That is a stronger and more specific spine than "housing is expensive", and it explains why the
shrinking metaphor works as well as it does. Worth using as a filter on future level ideas.

## 6. Steam long description — opening

The description opens with the fiction and moves into mechanics. Current draft (Spanish, as
written):

> En un futuro próximo, una vivienda se ha vuelto tan cara que la única forma de conseguir una es
> ganarla en el sorteo de un youtuber.
>
> Para aliviar la crisis, la recién creada Oficina para la Vivienda ha decretado reducir las
> rentas más bajas — por fax, a un tamaño más manejable.
>
> Como Técnico de Habitabilidad, tu trabajo es demostrar que ahí dentro cabe una persona.

Three beats: the problem, the policy, your job — closing on the joke rather than trailing into
the mechanics section.

Notes for whoever edits this:

- **The YouTuber giveaway is the strongest line.** It is specific, contemporary, and establishes
  "near future" more efficiently than any explanation could. It should stay first, because Steam
  truncates the description in preview and the first line is what most people read.
- **Protect the pun** in §1.1 through every localisation.
- Do not explain the fax. The joke works better unexplained, and §2's justifications are for
  internal consistency, not for the player.

## 7. Open questions

1. **Is the Housing Office an antagonist?** Currently neutral-bureaucratic, which is funnier and
   cheaper than a villain. A villain would need a plot; the Office only needs forms.
2. **Does the player ever get reduced?** Never established. It would be a strong late-game turn,
   and it interacts with the duplication rule.
3. **Do duplicates need housing?** See §3. Potentially a whole level family.
4. **How much fiction reaches the player at all?** The current assumption is: very little, all of
   it through ordinances, listings and tenant requests, with nobody in the world finding any of
   it remarkable. No cutscenes, no narrator.
