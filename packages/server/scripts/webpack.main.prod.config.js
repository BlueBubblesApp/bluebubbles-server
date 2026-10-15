const { merge } = require('webpack-merge');
const TerserPlugin = require('terser-webpack-plugin');

const baseConfig = require('./webpack.main.config');

module.exports = merge(baseConfig, {
    mode: 'production',
    optimization: {
        minimizer: [
            new TerserPlugin({
                terserOptions: {
                    keep_classnames: true,
                    // Decorated TypeORM entities may be emitted as functions.
                    // Their runtime names must remain distinct for relation sorting.
                    keep_fnames: true,
                },
            }),
        ],
    },
});
