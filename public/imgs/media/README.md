# Event photo library

Optional self-hosted event photos. An event's `featured_image` is resolved to a
displayable image by `src/lib/images.ts` (`resolveImageUrl`):

- a site path such as `/imgs/media/<file>.webp` → a photo in this folder, used as-is.
- an `https://…` URL → used as-is (the CSP allows `https://*.supabase.co`; add
  any other host there).

So there is **no CDN dependency at runtime** and nothing extra in the CSP beyond
`'self'`. This folder ships empty — a fork drops its own optimized `.webp` copies
here for the events it wants photos on. An event with no matching image (or no
`featured_image`) falls back to a gradient card and never breaks. Featured events
surface these prominently on the dashboard's "Featured trips" cards.

## Keep this folder small — GitHub gets hangry

Committed images live forever in git history and are pulled on every clone and CI
run. Stay well under GitHub's limits.

- **Per file:** GitHub *warns* over **50 MB** and *rejects* over **100 MB** (that
  needs Git LFS). Keep each image a pre-optimized `.webp`, ideally **under
  ~300 KB**.
- **This folder:** keep the total to a soft budget of **~50 MB**. Past that,
  clones/CI slow down and the repo drifts toward GitHub's recommended **1 GB**
  repo ceiling (they *strongly* recommend under 5 GB).

If you need many large/high-res images, don't commit them here — put them in
object storage (Supabase Storage, Cloudflare R2) and store the URL in
`featured_image` (URLs pass through `resolveImageUrl` unchanged), or use Git LFS.
