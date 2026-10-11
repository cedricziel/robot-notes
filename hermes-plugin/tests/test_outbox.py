import pytest

from robot_notes.outbox import Outbox, QueueFull


def test_restart_preserves_order_and_retries_ambiguous_delivery(tmp_path):
    path = tmp_path / 'outbox.sqlite'
    queue = Outbox(path)
    queue.enqueue({'kind': 'mirror', 'content': 'first'})
    queue.enqueue({'kind': 'mirror', 'content': 'second'})
    delivered = []

    def fail_after_acceptance(operation):
        delivered.append(operation['content'])
        raise OSError('timeout after acceptance')

    assert queue.deliver_one(fail_after_acceptance, lambda error: ('network_error', True)) is False
    resumed = Outbox(path)
    assert resumed.status()['pending'] == 2
    assert resumed.deliver_one(lambda operation: delivered.append(operation['content']))
    assert resumed.deliver_one(lambda operation: delivered.append(operation['content']))
    assert delivered == ['first', 'first', 'second']
    assert resumed.status()['pending'] == 0


def test_permanent_failure_blocks_later_operations(tmp_path):
    queue = Outbox(tmp_path / 'queue.sqlite')
    queue.enqueue({'content': 'first'})
    queue.enqueue({'content': 'second'})

    def deny(operation):
        raise PermissionError('secret server body')

    queue.deliver_one(deny, lambda error: ('auth', False))
    assert not queue.deliver_one(lambda operation: pytest.fail('blocked delivery attempted'))
    assert queue.status() == {'pending': 2, 'blocked': True, 'reason': 'auth', 'expired': 0}
    queue.retry_blocked()
    assert queue.deliver_one(lambda operation: None)


def test_expiry_removes_payload_and_reports_loss(tmp_path):
    now = [100.0]
    path = tmp_path / 'queue.sqlite'
    queue = Outbox(path, retention_seconds=10, clock=lambda: now[0])
    queue.enqueue({'content': 'expired private memory'})
    now[0] = 111.0
    assert not queue.deliver_one(lambda operation: pytest.fail('expired payload sent'))
    assert queue.status()['expired'] == 1
    assert queue.status()['pending'] == 0


def test_capacity_does_not_evict_an_older_write(tmp_path):
    queue = Outbox(tmp_path / 'queue.sqlite', max_operations=1)
    queue.enqueue({'content': 'first'})
    with pytest.raises(QueueFull):
        queue.enqueue({'content': 'second'})
    delivered = []
    assert queue.deliver_one(lambda operation: delivered.append(operation['content']))
    assert delivered == ['first']


def test_second_worker_cannot_deliver_an_inflight_operation(tmp_path):
    path = tmp_path / 'queue.sqlite'
    queue = Outbox(path)
    queue.enqueue({'content': 'first'})
    competing = Outbox(path)
    delivered = []

    def deliver(operation):
        assert not competing.deliver_one(lambda ignored: pytest.fail('duplicate worker'))
        delivered.append(operation['content'])

    assert queue.deliver_one(deliver)
    assert delivered == ['first']


def test_enqueue_remains_available_during_network_delivery(tmp_path):
    path = tmp_path / 'queue.sqlite'
    queue = Outbox(path)
    queue.enqueue({'content': 'first'})
    other = Outbox(path)

    def deliver(operation):
        other.enqueue({'content': 'second'})

    assert queue.deliver_one(deliver)
    assert queue.status()['pending'] == 1
    delivered = []
    assert other.deliver_one(lambda operation: delivered.append(operation['content']))
    assert delivered == ['second']
