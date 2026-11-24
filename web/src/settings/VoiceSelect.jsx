import { groupChoices, voiceLabel } from "./voiceChoices";

// The voice picker both Settings > Voice and the admin create business wizard use: grouped by provider, voices in the
// given languages first.

export function VoiceSelect({ value, onChange, choices, languages, defaultName, disabled }) {
  return (
    <select value={value} disabled={disabled} onChange={onChange}>
      <option value="">{defaultName ? `Zella Voice default (${defaultName})` : "Zella Voice default"}</option>
      {groupChoices(choices, languages).map((g) => (
        <optgroup key={g.provider} label={g.name}>
          {g.choices.map((c) => <option key={c.id} value={c.id}>{voiceLabel(c)}</option>)}
        </optgroup>
      ))}
    </select>
  );
}

