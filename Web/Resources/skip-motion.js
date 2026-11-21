// Registers SkipMotion's "skip-motion" component with SwiftUIWeb (https://github.com/Vitorsilveira31/SwiftUIWeb).
//
// A SwiftUIWeb app that uses SkipMotion serves this file and the player next to it from its own origin (its
// Web/Resources) and loads this file with a module script in its Resources/head.html (see the README). lottie-web, in
// the player, is imported the first time a MotionView is on the page, so a page without one downloads none of it.
// A release build renames both files by their content and rewrites the player's name below to match.
(globalThis.SwiftUIWebDOMComponents ??= { queue: [], define(name, factory) { this.queue.push([name, factory]); } })
  .define("skip-motion", () => import(new URL("./skip-motion-lottie.js", import.meta.url).href).then((module) => module.default));
