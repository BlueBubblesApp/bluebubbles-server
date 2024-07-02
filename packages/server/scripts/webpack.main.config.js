const path = require("path");
const { merge } = require("webpack-merge");
const ForkTsCheckerWebpackPlugin = require("fork-ts-checker-webpack-plugin");
const nodeExternals = require("webpack-node-externals");
const baseConfig = require("./webpack.base.config");

module.exports = merge(baseConfig, {
    target: "electron-main",
    externals: [
        nodeExternals(),
        nodeExternals({
            modulesDir: path.resolve(__dirname, '../../../node_modules'),
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
