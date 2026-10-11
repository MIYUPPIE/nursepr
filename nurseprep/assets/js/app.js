// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/nurseprep"
import topbar from "../vendor/topbar"

// Animates a number from 0 up to `data-count-to` on mount. A plain global
// hook (registered below), not a per-component colocated one-`mounted()`
// fires correctly on first connect *and* on every later LiveView
// client-side navigation, unlike the homepage's `initScrollReveal`/
// `animateCount` below, which run once against a one-time
// `querySelectorAll` on `DOMContentLoaded` and never see elements a
// sidebar-link navigation patches in afterward (that script is scoped to
// `[data-reveal]`, present only on the plain-HTML marketing page-this one
// is for LiveView dashboard pages, so it can't share that mechanism).
const CountUp = {
  mounted() {
    this.animate()
  },
  animate() {
    const target = parseInt(this.el.dataset.countTo, 10)
    if (Number.isNaN(target)) return

    const suffix = this.el.dataset.countSuffix || ""

    if (matchMedia("(prefers-reduced-motion: reduce)").matches) {
      this.el.textContent = target.toLocaleString() + suffix
      return
    }

    const duration = 700
    const start = performance.now()

    const step = now => {
      const progress = Math.min((now - start) / duration, 1)
      const eased = 1 - Math.pow(1 - progress, 3)
      this.el.textContent = Math.round(target * eased).toLocaleString() + suffix
      if (progress < 1) requestAnimationFrame(step)
    }

    requestAnimationFrame(step)
  }
}

// Filters the sidebar's quick-jump dropdown as the student types-purely a
// client-side filter over the real nav items already in the DOM (there's
// no full-text search backend over questions/subjects to call), so it
// only ever narrows down real routes rather than pretending to search
// content that isn't indexed anywhere.
const NavSearch = {
  mounted() {
    this.input = this.el.querySelector("[data-quick-jump-input]")
    this.items = this.el.querySelectorAll("[data-quick-jump-item]")
    this.input.addEventListener("input", () => this.filter())
  },
  filter() {
    const query = this.input.value.trim().toLowerCase()
    this.items.forEach(item => {
      const label = item.dataset.quickJumpLabel.toLowerCase()
      item.classList.toggle("hidden", query.length > 0 && !label.includes(query))
    })
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, CountUp, NavSearch},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// Homepage scroll-reveal + stat count-up. Scoped entirely to
// `[data-reveal]`/`[data-count-to]` elements (only present on the
// marketing page today), so this is a silent no-op everywhere else -
// no LiveView hook wiring needed since the home page is plain
// controller-rendered HTML, not a LiveView.
const initScrollReveal = () => {
  const revealEls = document.querySelectorAll("[data-reveal]")
  if (revealEls.length === 0) return

  const prefersReducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches

  // Stagger elements that reveal together (e.g. a grid of feature cards)
  // by their position among siblings sharing the same `data-reveal`
  // group, via a CSS custom property `app.css` reads as `--reveal-delay`.
  const groups = new Map()
  revealEls.forEach(el => {
    const group = el.dataset.reveal
    const index = groups.get(group) || 0
    el.style.setProperty("--reveal-delay", `${Math.min(index, 6) * 80}ms`)
    groups.set(group, index + 1)
  })

  const reveal = el => {
    el.classList.add("is-visible")
    if (prefersReducedMotion) return
    const countTo = el.hasAttribute("data-count-to") ? el : el.querySelector("[data-count-to]")
    if (countTo) animateCount(countTo)
  }

  if (prefersReducedMotion || !("IntersectionObserver" in window)) {
    revealEls.forEach(reveal)
    return
  }

  // The hero is above the fold - reveal it immediately rather than
  // waiting on an observer callback for something already on screen.
  document.querySelectorAll('[data-reveal="hero"]').forEach(reveal)

  const observer = new IntersectionObserver((entries, obs) => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        reveal(entry.target)
        obs.unobserve(entry.target)
      }
    })
  }, {rootMargin: "0px 0px -10% 0px", threshold: 0.1})

  revealEls.forEach(el => {
    if (el.dataset.reveal !== "hero") observer.observe(el)
  })
}

const animateCount = el => {
  const target = parseInt(el.dataset.countTo, 10)
  if (Number.isNaN(target) || el.dataset.counted) return
  el.dataset.counted = "true"

  const suffix = el.dataset.countSuffix || ""
  const duration = 900
  const start = performance.now()

  const step = now => {
    const progress = Math.min((now - start) / duration, 1)
    const eased = 1 - Math.pow(1 - progress, 3)
    el.textContent = Math.round(target * eased).toLocaleString() + suffix
    if (progress < 1) requestAnimationFrame(step)
  }

  requestAnimationFrame(step)
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", initScrollReveal)
} else {
  initScrollReveal()
}

// Marketing-page sticky header: adds a border/shadow once the page has
// scrolled past the header itself, so it reads as "elevated" over
// content instead of floating with the exact same flat look at every
// scroll position. Passive + rAF-throttled since scroll fires far more
// often than a layout actually needs to update.
const initStickyHeaderElevation = () => {
  const header = document.querySelector("[data-elevate-on-scroll]")
  if (!header) return

  let ticking = false
  const update = () => {
    header.classList.toggle("is-elevated", window.scrollY > 8)
    ticking = false
  }

  window.addEventListener("scroll", () => {
    if (!ticking) {
      requestAnimationFrame(update)
      ticking = true
    }
  }, {passive: true})

  update()
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", initStickyHeaderElevation)
} else {
  initStickyHeaderElevation()
}

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

