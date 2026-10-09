export function stringSimilarity(str1: string, str2: string): number {
  const s1 = str1.toLowerCase().trim();
  const s2 = str2.toLowerCase().trim();
  if (s1 === s2) return 1.0;
  if (s1.includes(s2) || s2.includes(s1)) return 0.8;
  return 0.0;
}

export function rankMusicResults(
  results: any[],
  targetTitle?: string,
  targetArtist?: string,
  targetQuery?: string
) {
  return results.map(r => {
    let score = 0;
    const rTitle = r.trackName || '';
    const rArtist = r.artistName || '';

    if (targetTitle) {
      const sim = stringSimilarity(targetTitle, rTitle);
      score += sim * 5;
    }
    if (targetArtist) {
      const sim = stringSimilarity(targetArtist, rArtist);
      score += sim * 10; // Artist match heavily outweighs title
    }
    
    if (targetQuery) {
       const simT = stringSimilarity(targetQuery, rTitle);
       const simA = stringSimilarity(targetQuery, rArtist);
       score += Math.max(simT, simA) * 2;
    }

    return { ...r, _score: score };
  }).sort((a, b) => b._score - a._score);
}
