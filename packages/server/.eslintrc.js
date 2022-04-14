module.exports = {
    "env": {
        "es6": true,
        "node": true
    },
    "ignorePatterns": [
        "build",
        "dist",
        "scripts/**/*",
        "node_modules"
    ],
    "extends": [
        "eslint:recommended",
        "plugin:import/recommended",
        "plugin:import/typescript",
        "plugin:import/electron",
        "plugin:@typescript-eslint/recommended",
        "prettier"
    ],
    "parser": "@typescript-eslint/parser",
    "parserOptions": {
        "ecmaFeatures": {
            "jsx": true
        },
        "ecmaVersion": 2018,
        "sourceType": "module",
        "tsconfigRootDir": __dirname,
        "project": "tsconfig.json"
    },
    "plugins": ["prettier", "@typescript-eslint"],
    "rules": {
        "no-restricted-syntax": "off",
        "no-await-in-loop": "off",
        "no-console": 0,
        "no-continue": "off",
        "no-unreachable": "warn",
        "global-require": 0,
        "max-len": ["error", { "code": 120 }],
        "import/prefer-default-export": 0,
        "import/no-useless-path-segments": 1,
        "import/no-unresolved": 0,
        "import/no-extraneous-dependencies": 0,
        "import/no-named-as-default": 0,
        "import/newline-after-import": 1,
        "import/no-named-as-default-member": 0,
        "import/namespace": 0,
        "import/extensions": 0,
        "import/named": 0,
        "@typescript-eslint/no-var-requires": 0,
        "@typescript-eslint/indent": 0,
        "@typescript-eslint/camelcase": 0,
        "@typescript-eslint/explicit-function-return-type": 0,
        "@typescript-eslint/no-non-null-assertion": 0,
        "@typescript-eslint/no-use-before-define": 0,
        "@typescript-eslint/member-delimiter-style": 0,
        "@typescript-eslint/no-unused-vars": 0,
        "@typescript-eslint/no-explicit-any": 0,
        "@typescript-eslint/no-param-reassign": 0,
        "@typescript-eslint/explicit-member-accessibility": 0,
        "@typescript-eslint/no-angle-bracket-type-assertion": 0

    }
};
