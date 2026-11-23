// Appended only to the local QA entry. Normal play/src/main.js stays byte-identical.
import { installRecorder } from '../device/recorder.js';
const [deviceBuild, fieldStations] = await Promise.all(['build.json', 'stations.json'].map(async file => {
  const response = await fetch(new URL('../device/' + file, import.meta.url));
  if (!response.ok) throw Error('Cannot open local QA metadata: ' + file);
  return response.json();
}));
const stationPoses = Object.fromEntries(fieldStations.map(station => [station.id, station.pose]));
stationPoses['canal-west'] = [7, -67, 45, -10];
installRecorder({
  build: deviceBuild, renderer: () => renderer, player, quality, stations: stationPoses,
  moveTo(pose) {
    if (!pose || !campus.canStand(pose[0], pose[1])) return false;
    player.x = pose[0];
    player.z = pose[1];
    player.yaw = Math.atan2(pose[0]-pose[2], pose[1]-pose[3]);
    updateCamera();
    refreshHud();
    return true;
  },
});
