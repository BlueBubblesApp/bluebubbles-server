const path = require("path");

module.exports = {
    mode: "development",
    output: {
        path: path.resolve(__dirname, "../dist"),
        filename: "[name].js"
    },
    node: {
        __dirname: false,
        __filename: false
    },
    resolve: {
        extensions: [".tsx", ".ts", ".js", ".json"],
        alias: {
            "@server": path.resolve(__dirname, "../src/server"),
            "@windows": path.resolve(__dirname, "../src/windows"),
            "@trays": path.resolve(__dirname, "../src/trays")
        }
    },
    devtool: "source-map",
    plugins: []
};
