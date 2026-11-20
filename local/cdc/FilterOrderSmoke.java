// Runs against the actual installed jars, not a mocked transform implementation.
import io.debezium.transforms.Filter;
import io.debezium.transforms.outbox.EventRouter;
import org.apache.kafka.connect.data.Schema;
import org.apache.kafka.connect.data.SchemaBuilder;
import org.apache.kafka.connect.data.Struct;
import org.apache.kafka.connect.source.SourceRecord;
import java.util.Map;

public class FilterOrderSmoke {
    public static void main(String[] args) {
        var filter = new Filter<SourceRecord>();
        filter.configure(Map.of("language", "jsr223.groovy", "condition",
            "value != null && (value.op == 'c' || value.op == 'r') && value.after != null && value.after.topic == 'commerce.catalog.snapshots.v1'"));
        var router = new EventRouter<SourceRecord>();
        router.configure(Map.of("table.field.event.id", "event_id", "table.field.event.key", "message_key",
            "route.by.field", "topic", "table.fields.additional.placement",
            "event_id:header:eventId,event_type:header:eventType"));
        // Deliberately lacks all fields required by EventRouter, including payload.
        // This proves excluded records are discarded before schema validation.
        Schema afterSchema = SchemaBuilder.struct().name("smoke.Value").field("topic", Schema.STRING_SCHEMA).build();
        Schema envelopeSchema = SchemaBuilder.struct().name("smoke.Envelope")
            .field("before", SchemaBuilder.struct().optional().build())
            .field("after", afterSchema).field("source", SchemaBuilder.struct().build())
            .field("op", Schema.STRING_SCHEMA).field("ts_ms", Schema.INT64_SCHEMA).build();
        Struct after = new Struct(afterSchema).put("topic", "commerce.refund.requests.v1");
        Struct envelope = new Struct(envelopeSchema).put("after", after).put("op", "c")
            .put("source", new Struct(envelopeSchema.field("source").schema())).put("ts_ms", 1L);
        var record = new SourceRecord(Map.of("server", "smoke"), Map.of("lsn", 1L),
            "core_catalog_cdc.public.event_outbox", null, null, envelopeSchema, envelope);
        if (filter.apply(record) != null) throw new AssertionError("excluded record escaped filter");
        boolean failedAsExpected = false;
        try { router.apply(record); }
        catch (org.apache.kafka.connect.errors.ConnectException e) {
            if (!e.getMessage().contains("payload")) throw e;
            failedAsExpected = true;
        }
        if (!failedAsExpected) throw new AssertionError("router did not validate missing payload");
        after.put("topic", "commerce.catalog.snapshots.v1");
        if (filter.apply(record) == null) throw new AssertionError("catalog insert was filtered");
        envelope.put("op", "u");
        if (filter.apply(record) != null) throw new AssertionError("update escaped filter");
        envelope.put("op", "d");
        if (filter.apply(record) != null) throw new AssertionError("delete escaped filter");
        filter.close(); router.close();
        System.out.println("PASS 5 transform checks: exclude before schema validation, reversed order rejects schema, include catalog insert, exclude update, exclude delete");
    }
}
