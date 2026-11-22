import { MAIN_ENTRANCE } from './basic-campus.js';
export const TOUR_STOPS = Object.freeze([
  // zone is a deprecated compatibility field for old QA/callers; live tour uses placeZoneId.
  { id: "gate", label: "정문 통과", placeZoneId:'AREA_MAIN_GATE', zone: "C01_GATE", x: 0, z: -76, radius: 7 },
  { id: "main", label: "본관 앞", placeZoneId:'AREA_MAIN_HALL', zone: "C02_MAIN_HALL", x: MAIN_ENTRANCE.x, z: MAIN_ENTRANCE.z, radius: 9 }
]);
