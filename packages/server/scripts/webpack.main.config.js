const path = require("path");
const { merge } = require("webpack-merge");
const ForkTsCheckerWebpackPlugin = require("fork-ts-checker-webpack-plugin");
const nodeExternals = require("webpack-node-externals");
const baseConfig = require("./webpack.base.config");

// node-fetch 3 is ESM-only, and Electron 25 can't load ESM from app.asar at runtime, so it (and its
// ESM dependencies) are bundled instead. See src/server/lib/gaxiosFetch.ts.
const allowlist = [
    /^node-fetch(\/|$)/,
    /^fetch-blob(\/|$)/,
    /^formdata-polyfill(\/|$)/,
    /^data-uri-to-buffer(\/|$)/,
    /^web-streams-polyfill(\/|$)/,
    /^node-domexception(\/|$)/
];

module.exports = merge(baseConfig, {
    target: "electron-main",
    externals: [
        nodeExternals({ allowlist }),
        nodeExternals({
            modulesDir: path.resolve(__dirname, '../../../node_modules'),
            allowlist
        }),
    ],
    entry: {
        main: "./src/main.ts"
    },
    module: {
        rules: [
            {
                test: /\.tsx?$/,
                exclude: /node_modules/,
                loader: "babel-loader",
                options: {
                    cacheDirectory: true,
                    babelrc: false,
                    presets: [
                        [
                            "@babel/preset-env",
                            { targets: "maintained node versions" }
                        ],
                        "@babel/preset-typescript"
                    ],
                    plugins: [
                        ["@babel/plugin-proposal-decorators", { legacy: true }],
                        [
                            "@babel/plugin-transform-class-properties",
                            { loose: true }
                        ],
                        [
                            "@babel/plugin-transform-private-methods",
                            { loose: true }
                        ],
                        [
                            "@babel/plugin-transform-private-property-in-object",
                            { loose: true }
                        ]
                    ]
                }
            }
        ]
    },
    plugins: [
        new ForkTsCheckerWebpackPlugin({
            typescript: {
                configFile: path.resolve(__dirname, '../tsconfig.json')
            }
        })
    ]
});
