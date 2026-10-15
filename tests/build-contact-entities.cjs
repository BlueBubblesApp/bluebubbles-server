const path = require("path");
const root = path.resolve(__dirname, "..");
process.chdir(path.join(root, "packages/server"));
const webpack = require("webpack");
const base = require("../packages/server/scripts/webpack.main.prod.config.js");
webpack(
  {
    ...base,
    context: process.cwd(),
    entry: { contacts: path.join(__dirname, "contact-entities-entry.cjs") },
    plugins: [],
    devtool: false,
    output: {
      path: path.join(__dirname, ".build"),
      filename: "contacts.cjs",
      library: { type: "commonjs2" },
    },
  },
  (err, stats) => {
    if (err || stats.hasErrors()) {
      console.error(
        err?.message || stats.toString({ all: false, errors: true })
      );
      process.exitCode = 1;
    } else console.log("Contact fixture compiled with production minification");
  }
);
