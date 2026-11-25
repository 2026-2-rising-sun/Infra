# Catalog 상품 검색용 Elasticsearch. 한국어 상품명을 쪼개는 Nori 분석기를 넣는다.
# 버전은 Backend catalog-service 의 elasticsearch-java 클라이언트(8.18.8)와 맞춘다.
FROM docker.elastic.co/elasticsearch/elasticsearch:8.18.8
RUN bin/elasticsearch-plugin install --batch analysis-nori
