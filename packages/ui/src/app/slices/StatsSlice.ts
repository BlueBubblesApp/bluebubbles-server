import { createSlice, PayloadAction } from '@reduxjs/toolkit';

const initialState: NodeJS.Dict<any> = {};

export type StatItem = {
    name: string,
    value: any
};

export const StatsSlice = createSlice({
    name: 'stats',
    initialState,
    reducers: {
        setStat: (state, action: PayloadAction<StatItem>) => {
            state[action.payload.name] = action.payload.value;
        }
    }
});

// Action creators are generated for each case reducer function
export const { setStat } = StatsSlice.actions;

export default StatsSlice.reducer;