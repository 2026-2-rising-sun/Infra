// 시나리오 4: 파티션 튜닝 비교.
//
// 시나리오 1 을 그대로 다시 돌린다. 차이는 돌리기 전에 바꾸는 설정뿐이다.
//   1) KafkaTopic live.broadcast.v1 의 partitions 6 → 12 (k8s/overlays/dev/datatier)
//   2) notification ScaledObject 의 maxReplicaCount 를 파티션 수에 맞춤 (k8s/overlays/dev/scaling)
// 같은 USERS 로 1 → 4 를 돌리고 "notification 랙이 0 으로 돌아오는 시간"을 비교한다.
// 결과 표의 열은 docs/performance/RESULTS-TEMPLATE.md 에 있다.
//
// 어느 설정으로 돌렸는지 testid 와 PARTITIONS 태그로 남긴다:
//   ./tests/performance/k6/run.sh 04 -e PARTITIONS=12 -e USERS=200
import { options as surge, setup, default as viewer } from './01-broadcast-start-surge.js';

export { setup };
export default viewer;

export const options = {
  ...surge,
  tags: { scenario: 'partition-tuning', partitions: String(__ENV.PARTITIONS || 'unset') },
};
