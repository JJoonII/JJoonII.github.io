# tools

## compress-video.ps1

홈페이지에 올릴 mp4를 웹 배포용으로 압축한다. 저장소 루트에서 실행한다.

```powershell
# images\video 안에서 아직 압축 안 한 mp4를 전부 처리한다
.\tools\compress-video.ps1

# 특정 파일만
.\tools\compress-video.ps1 images\video\demo.mp4

# 더 작게 (화질은 조금 포기)
.\tools\compress-video.ps1 images\video\demo.mp4 -Width 960 -Crf 28
```

### 무엇을 하는가

- 폭을 `-Width`(기본 1280)로 축소한다. 원본이 더 좁으면 확대하지 않는다.
- H.264 / CRF `-Crf`(기본 24) / `-Preset`(기본 slow) / yuv420p로 다시 인코딩한다.
  yuv420p는 브라우저 호환성 때문이니 바꾸지 않는 편이 좋다.
- `+faststart`로 moov 박스를 파일 앞으로 보낸다. 다 받기 전에 재생이 시작된다.
- 오디오가 무음이면 트랙째 버린다. 데모 영상은 대개 무음인데 그냥 두면 수 MB를 먹는다.
  (`-KeepAudio`로 끌 수 있다.)

### 원본 보관

원본은 같은 폴더의 `_originals\`로 옮겨 보관하며, 이 폴더는 `.gitignore`에서 제외된다.
`_originals\`에 같은 이름이 이미 있으면 "전에 압축한 파일"로 보고 건너뛴다.
**즉 여러 번 실행해도 안전하고, 압축본을 다시 압축하지 않는다.**

되돌리려면 `_originals\`에서 파일을 꺼내 덮어쓰면 된다.

### ffmpeg

PATH에 없으면 `%LOCALAPPDATA%\ffmpeg-static\`에 자동으로 내려받는다(약 160MB).
시스템 설치가 아니라 압축만 푸는 것이라 관리자 권한이 필요 없고, 한 번 받으면 계속 재사용한다.
저장소가 OneDrive 안이라 일부러 저장소 밖에 캐시한다 — 안에 두면 300MB가 통째로 동기화된다.

### 실제 결과

| 파일 | 이전 | 이후 |
|---|---|---|
| `PairGS_short_video.mp4` | 87.5 MB (2160×932) | 5.67 MB (1280×552) |
| `Real2Sim_VLA.mp4` | 16.9 MB (2160×624) | 1.01 MB (1280×370) |
| `CF3_demo.mp4` | 18.0 MB (1700×590) | 1.44 MB (1280×444) |

### 주의

해상도가 바뀌므로, `index.html`에서 해당 영상에 `aspect-ratio`를 지정해 뒀다면
새 치수에 맞게 고쳐야 한다. 토글 영상은 각 `<video>`의 inline `style`에 들어 있다
(`preload="none"`이라 이 값이 없으면 재생 시작 순간 레이아웃이 튄다).

### 파일이 여전히 크면

`-Width`를 먼저 줄이고, 그래도 크면 `-Crf`를 올린다.
CRF는 값이 클수록 화질이 낮고 파일이 작다 — 18은 거의 무손실, 23이 기본, 28부터 눈에 띄게 열화된다.
