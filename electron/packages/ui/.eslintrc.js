module.exports = {
    "env": {
        "browser": true,
        "es2021": true
    },
    "ignorePatterns": [
        "build",
        "dist",
        "node_modules",
        "config-overrides.js"
    ],
    "extends": [
        "eslint:recommended",
        "plugin:react/recommended",
        "plugin:@typescript-eslint/recommended",
        "prettier"
    ],
    "parser": "@typescript-eslint/parser",
    "parserOptions": {
        "ecmaFeatures": {
            "jsx": true,
            "modules": true
        },
        "ecmaVersion": 13,
        "sourceType": "module",
        "tsconfigRootDir": __dirname,
        "project": "tsconfig.json"
    },
    "plugins": [
        "react",
        "@typescript-eslint",
        "prettier"
    ],
    "rules": {
        "indent": [
            "error",
            4
        ],
        "linebreak-style": [
            "error",
            "unix"
        ],
        "quotes": [
            "error",
            "single"
        ],
        "semi": [
            "error",
            "always"
        ],
        "react/no-unescaped-entities": "off",
        "@typescript-eslint/no-explicit-any": "off",
        "@typescript-eslint/no-non-null-assertion": "off",
    }
};
