const path = require("path");
const webpack = require("webpack");
const merge = require("webpack-merge");
const ForkTsCheckerWebpackPlugin = require("fork-ts-checker-webpack-plugin");
const nodeExternals = require("webpack-node-externals");
const baseConfig = require("./webpack.base.config");

module.exports = merge.smart(baseConfig, {
    target: "electron-main",
    externals: [nodeExternals()],
    entry: {
        main: "./src/main/main.ts"
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
                            "@babel/plugin-proposal-class-properties",
                            { loose: true }
                        ]
                    ]
                }
            }
        ]
    },
    plugins: [
        // new ForkTsCheckerWebpackPlugin({
        //     reportFiles: ["src/main/**/*"]
        // }),
        new webpack.DefinePlugin({
            "process.env.NODE_ENV": JSON.stringify(
                process.env.NODE_ENV || "development"
            )
        })
    ]
});
