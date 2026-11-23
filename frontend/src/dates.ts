// The API sends posting times as UTC ISO 8601. Show them in the phone's own
// timezone with one consistent, readable format.
export function formatDate(iso?: string): string {
  if (!iso) return '';
  const value = new Date(iso);
  if (Number.isNaN(value.getTime())) return '';
  return value.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
}

export const postedLabel = (iso?: string) => {
  const date = formatDate(iso);
  return date ? `Posted ${date}` : '';
};
