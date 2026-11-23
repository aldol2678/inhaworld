import * as THREE from '../vendor/three.module.js';

// The four source corners also own the terrain cut and the capsule obstruction.
// Sky / canopy reflections are analytical. No field imagery or reflection camera is sampled.
export function canalWater(ring, fog) {
  if (ring.length !== 4) throw Error('Expected the surveyed four-corner reflecting pool');
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute(
    'position',
    new THREE.Float32BufferAttribute(
      ring.flatMap((p) => [p.x, 0.025, p.z]),
      3,
    ),
  );
  geometry.setAttribute('uv', new THREE.Float32BufferAttribute([0, 1, 1, 1, 1, 0, 0, 0], 2));
  geometry.setIndex([0, 1, 2, 0, 2, 3]);
  const uniforms = {
    phase: { value: 0 },
    detail: { value: 0 },
    fogColor: { value: fog.color },
    fogRange: { value: new THREE.Vector2(fog.near, fog.far) },
  };
  const material = new THREE.ShaderMaterial({
    uniforms,
    side: THREE.DoubleSide,
    vertexShader: `
      varying vec2 lane; varying vec3 world; varying float depth;
      void main() {
        lane=uv; world=(modelMatrix*vec4(position,1.)).xyz;
        vec4 eye=viewMatrix*vec4(world,1.);
        depth=-eye.z; gl_Position=projectionMatrix*eye;
      }`,
    fragmentShader: `
      varying vec2 lane; varying vec3 world; varying float depth;
      uniform float phase, detail; uniform vec3 fogColor; uniform vec2 fogRange;
      void main() {
        vec3 view=normalize(cameraPosition-world);
        float edge=abs(2.*lane.x-1.);
        float grazing=pow(1.-clamp(view.y,0.,1.),3.);
        vec3 water=mix(vec3(.053,.215,.206),vec3(.14,.31,.26),edge*edge);
        vec3 sky=vec3(.40,.56,.65);
        if(detail>.5){
          float wave=sin(190.*lane.y+3.*sin(lane.x*8.)+phase*1.2)
                     *sin(52.*lane.y-3.*lane.x-phase*.64);
          float band=smoothstep(.38,.95,edge+.11*wave);
          float trees=.5+.5*sin(lane.y*51.+view.x*2.+wave*.35);
          sky=mix(sky,vec3(.12,.22,.15),band*(.4+.43*trees));
          water+=vec3(.021,.027,.024)*wave*(1.-smoothstep(0.,.08,fwidth(lane.y)));
          if(detail>1.5){
            vec3 n=normalize(vec3(.035*wave,1.,.045*sin(79.*lane.y+phase)));
            float glint=pow(max(dot(reflect(-normalize(vec3(2.,3.,1.)),n),view),0.),48.);
            water+=vec3(.50,.45,.34)*glint;
          }
        }
        vec3 color=mix(water,sky,.12+.61*grazing);
        color=mix(color,fogColor,smoothstep(fogRange.x,fogRange.y,depth));
        gl_FragColor=vec4(color,1.);
        #include <colorspace_fragment>
      }`,
  });
  const mesh = new THREE.Mesh(geometry, material);
  mesh.name = 'reflecting-pool';
  return { mesh, uniforms };
}
