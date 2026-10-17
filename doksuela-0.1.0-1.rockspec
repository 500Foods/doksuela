rockspec_format = "3.0"
package = "doksuela"
version = "0.1.0-1"
source = {
  url = "git+https://github.com/500Foods/doksuela.git",
}
description = {
  summary = "Terminal UI for DigitalOcean Kubernetes clusters",
  detailed = [[
A mouse-driven terminal UI that joins doctl, kubectl, and clusterlint
for one DOKS cluster. Cached counts show in blue until a live check
confirms them.
]],
  homepage = "https://github.com/500Foods/doksuela",
  license = "MIT",
}
dependencies = {
  "lua >= 5.5, < 5.6",
  "terminal >= 0.1",
  "dkjson >= 2.5",
}
build = {
  type = "builtin",
  modules = {
    ["doksuela.app"] = "src/app.lua",
    ["doksuela.bincheck"] = "src/bincheck.lua",
    ["doksuela.cache"] = "src/cache.lua",
    ["doksuela.checks"] = "src/checks.lua",
    ["doksuela.clock"] = "src/clock.lua",
    ["doksuela.exec"] = "src/exec.lua",
    ["doksuela.fresh"] = "src/fresh.lua",
    ["doksuela.json"] = "src/json.lua",
    ["doksuela.listwin"] = "src/listwin.lua",
    ["doksuela.log"] = "src/log.lua",
    ["doksuela.match"] = "src/match.lua",
    ["doksuela.model"] = "src/model.lua",
    ["doksuela.queue"] = "src/queue.lua",
    ["doksuela.session"] = "src/session.lua",
    ["doksuela.shape"] = "src/shape.lua",
    ["doksuela.textfit"] = "src/textfit.lua",
    ["doksuela.ui.mouse"] = "src/ui/mouse.lua",
    ["doksuela.ui.theme"] = "src/ui/theme.lua",
    ["dkjson"] = "src/vendor/dkjson.lua",
  },
  install = {
    bin = {
      doksuela = "doksuela.lua",
    },
  },
}
