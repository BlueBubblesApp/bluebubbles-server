import React from 'react';

import './App.css';
import { Navigation } from './containers/navigation/Navigation';
import { Setup } from './containers/setup/Setup';
import { useAppSelector } from './hooks';

const App = (): JSX.Element => {
    const isSetupComplete: boolean = useAppSelector(state => state.config.tutorial_is_done) ?? false;
    if (isSetupComplete) {
        return (<Navigation />);
    } else {
        return (<Setup />);
    }
};

export default App;
