import { CounterAction } from './counterActions';

export type RootActions = CounterAction[keyof CounterAction];
